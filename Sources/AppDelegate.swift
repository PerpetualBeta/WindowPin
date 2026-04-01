import AppKit
import ApplicationServices
import SwiftUI
import ServiceManagement

// MARK: - Global CGEvent tap callback (must be a C-compatible function)

private var _hotkeyAction: (() -> Void)?
private var _eventTap: CFMachPort?
private var _shortcutKeyCode: Int64 = 35
private var _shortcutCGModifiers: CGEventFlags = [.maskCommand, .maskControl]

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = _eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    if keyCode == _shortcutKeyCode {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        if flags.intersection(relevant) == _shortcutCGModifiers.intersection(relevant) {
            DispatchQueue.main.async {
                _hotkeyAction?()
            }
            return nil
        }
    }

    return Unmanaged.passRetained(event)
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let tracker = PinnedWindowTracker()
    let updateChecker = JorvikUpdateChecker(repoName: "WindowPin")

    private var lastForeignWindow: ForeignWindow?
    private var focusObserver: NSObjectProtocol?

    var shortcutKeyCode: UInt16 = 35
    var shortcutModifiers: NSEvent.ModifierFlags = [.command, .control]

    /// Expose the CGEvent tap for JorvikShortcutRecorder to temporarily disable during recording
    var currentEventTap: CFMachPort? { _eventTap }

    private var permissionTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        wplog("Accessibility trusted: \(trusted)")

        loadShortcut()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        JorvikMenuBarPill.apply(to: statusItem.button!)
        updateChecker.checkOnSchedule()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tracker.onChange = { [weak self] in
            self?.updateIcon()
        }

        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let myPID = ProcessInfo.processInfo.processIdentifier
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != myPID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let fw = WindowDetector.getFrontmostForeignWindow() {
                        self.lastForeignWindow = fw
                    }
                }
            }
        }

        registerHotkey()

        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        wplog("Launched successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        if let tap = _eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let obs = focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        tracker.unpinAll()
    }

    @objc private func appearanceChanged() {
        if let button = statusItem.button {
            JorvikMenuBarPill.refresh(on: button)
        }
    }

    // MARK: - Icon

    private func updateIcon() {
        let hasPinned = !tracker.pinnedWindows.isEmpty
        let symbolName = hasPinned ? "pin.fill" : "pin"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WindowPin") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = hasPinned ? "📌" : "📍"
        }
    }

    // MARK: - Dynamic menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let aboutItem = NSMenuItem(title: "About WindowPin", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())

        // Pin/Unpin action
        let targetWindow = WindowDetector.getFrontmostForeignWindow() ?? lastForeignWindow

        if let fw = targetWindow {
            let isPinned = tracker.isPinned(windowID: fw.windowID)
            let displayName = fw.windowTitle.isEmpty ? fw.ownerName : fw.windowTitle
            let label = isPinned
                ? "Unpin \"\(truncate(displayName, max: 30))\""
                : "Pin \"\(truncate(displayName, max: 30))\""
            let item = NSMenuItem(title: label, action: #selector(toggleFrontmost), keyEquivalent: "")
            item.representedObject = fw
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "No window to pin", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        // Pinned windows list
        if !tracker.pinnedWindows.isEmpty {
            menu.addItem(NSMenuItem.separator())

            let header = NSMenuItem(title: "Pinned Windows", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let sorted = tracker.pinnedWindows.sorted { $0.displayLabel < $1.displayLabel }
            for pw in sorted {
                let item = NSMenuItem(title: "  \(pw.displayLabel)", action: #selector(unpinMenuItem(_:)), keyEquivalent: "")
                item.representedObject = pw.windowID
                item.state = .on
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())

            let unpinAll = NSMenuItem(title: "Unpin All", action: #selector(unpinAllAction), keyEquivalent: "")
            menu.addItem(unpinAll)
        }

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowPin", action: #selector(quit), keyEquivalent: "q"))
    }

    // MARK: - Actions

    @objc private func toggleFrontmost(_ sender: NSMenuItem) {
        guard let fw = sender.representedObject as? ForeignWindow else { return }
        tracker.toggle(window: fw)
    }

    @objc private func unpinMenuItem(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? UInt32 else { return }
        tracker.unpin(windowID: windowID)
    }

    @objc private func unpinAllAction() {
        tracker.unpinAll()
    }

    @objc private func quit() {
        tracker.unpinAll()
        NSApp.terminate(nil)
    }

    // MARK: - About & Settings

    @objc private func openAbout() {
        JorvikAboutView.showWindow(
            appName: "WindowPin",
            repoName: "WindowPin",
            productPage: "utilities/windowpin"
        )
    }

    @objc private func openSettings() {
        let trackerRef = tracker
        let delegate = self
        JorvikSettingsView.showWindow(
            appName: "WindowPin",
            updateChecker: updateChecker
        ) {
            WindowPinSettingsContent(tracker: trackerRef, delegate: delegate)
        }
    }

    // MARK: - Global hotkey (CGEvent tap)

    private func registerHotkey() {
        _hotkeyAction = { [weak self] in
            self?.togglePinFrontmostWindow()
        }
        _shortcutKeyCode = Int64(shortcutKeyCode)
        _shortcutCGModifiers = nsToCGModifiers(shortcutModifiers)

        if !tryCreateEventTap() {
            wplog("registerHotkey: waiting for Accessibility permission…")
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    wplog("registerHotkey: permission granted, retrying tap…")
                    if self?.tryCreateEventTap() == true {
                        timer.invalidate()
                        self?.permissionTimer = nil
                    }
                }
            }
        }
    }

    private func tryCreateEventTap() -> Bool {
        if _eventTap != nil { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: nil
        ) else {
            wplog("tryCreateEventTap: CGEvent.tapCreate failed (trusted=\(AXIsProcessTrusted()))")
            return false
        }

        _eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        wplog("tryCreateEventTap: SUCCESS — hotkey active for keyCode=\(shortcutKeyCode)")
        return true
    }

    private func togglePinFrontmostWindow() {
        guard let fw = WindowDetector.getFrontmostForeignWindow() else {
            wplog("togglePin: No foreign window found")
            return
        }
        let wasPinned = tracker.isPinned(windowID: fw.windowID)
        tracker.toggle(window: fw)
        let action = wasPinned ? "Unpinned" : "Pinned"
        let title = fw.windowTitle.isEmpty ? fw.ownerName : fw.windowTitle
        wplog("togglePin: \(action) '\(title)' (wid=\(fw.windowID))")
    }

    // MARK: - Shortcut configuration

    private func loadShortcut() {
        let kc = UserDefaults.standard.integer(forKey: "shortcutKeyCode")
        let mod = UserDefaults.standard.integer(forKey: "shortcutModifiers")
        if kc != 0 && mod != 0 {
            shortcutKeyCode = UInt16(kc)
            shortcutModifiers = NSEvent.ModifierFlags(rawValue: UInt(mod))
        }
    }

    func saveShortcutAndUpdateTap() {
        saveShortcut()
    }

    private func saveShortcut() {
        UserDefaults.standard.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode")
        UserDefaults.standard.set(Int(shortcutModifiers.rawValue), forKey: "shortcutModifiers")
        _shortcutKeyCode = Int64(shortcutKeyCode)
        _shortcutCGModifiers = nsToCGModifiers(shortcutModifiers)
    }

    // Shortcut recording is handled by JorvikShortcutRecorder in JorvikKit

    func shortcutDisplayString() -> String {
        var parts: [String] = []
        if shortcutModifiers.contains(.control) { parts.append("⌃") }
        if shortcutModifiers.contains(.option) { parts.append("⌥") }
        if shortcutModifiers.contains(.shift) { parts.append("⇧") }
        if shortcutModifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToCharacter(shortcutKeyCode))
        return parts.joined()
    }

    private func keyCodeToCharacter(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[keyCode] ?? "?\(keyCode)"
    }

    private func nsToCGModifiers(_ ns: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg: CGEventFlags = []
        if ns.contains(.command) { cg.insert(.maskCommand) }
        if ns.contains(.control) { cg.insert(.maskControl) }
        if ns.contains(.option) { cg.insert(.maskAlternate) }
        if ns.contains(.shift) { cg.insert(.maskShift) }
        return cg
    }

    // MARK: - Helpers

    private func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }
}
