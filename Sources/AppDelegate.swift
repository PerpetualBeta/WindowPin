import AppKit
import ApplicationServices
import SwiftUI

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
    // Re-enable tap if it was disabled by the system
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
            return nil // consume the event
        }
    }

    return Unmanaged.passRetained(event)
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let tracker = PinnedWindowTracker()
    private var aboutPopover: NSPopover?
    private var aboutMonitor: Any?

    /// Cached last-known frontmost foreign window (before our menu steals focus).
    private var lastForeignWindow: ForeignWindow?
    private var focusObserver: NSObjectProtocol?

    /// Current shortcut configuration
    private var shortcutKeyCode: UInt16 = 35
    private var shortcutModifiers: NSEvent.ModifierFlags = [.command, .control]

    /// Retry timer for CGEvent tap (waits for Accessibility permission)
    private var permissionTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Request Accessibility permission (prompts user if not yet granted)
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        wplog("Accessibility trusted: \(trusted)")

        // Load saved shortcut
        loadShortcut()

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Track changes to update icon
        tracker.onChange = { [weak self] in
            self?.updateIcon()
        }

        // Track frontmost app changes so we always know the last foreign window
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

        // Register global hotkey via CGEvent tap
        registerHotkey()

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

        // When menu opens, WindowPin is frontmost — use cached last foreign window
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

        let shortcutDisplay = shortcutDisplayString()
        let changeItem = NSMenuItem(title: "Change Shortcut (\(shortcutDisplay))…", action: #selector(changeShortcut), keyEquivalent: "")
        menu.addItem(changeItem)

        // Capture rate submenu
        let rateItem = NSMenuItem(title: "Capture Rate", action: nil, keyEquivalent: "")
        let rateMenu = NSMenu()
        let currentRate = WindowOverlay.captureRate
        for rate: Double in [0.5, 1, 2, 5, 10, 15, 30] {
            let label = rate < 1 ? String(format: "%.1f fps", rate) : "\(Int(rate)) fps"
            let item = NSMenuItem(title: label, action: #selector(setCaptureRate(_:)), keyEquivalent: "")
            item.representedObject = rate
            item.state = abs(currentRate - rate) < 0.01 ? .on : .off
            rateMenu.addItem(item)
        }
        rateItem.submenu = rateMenu
        menu.addItem(rateItem)

        let allSpacesItem = NSMenuItem(title: "Pin to All Spaces", action: #selector(toggleAllSpaces), keyEquivalent: "")
        allSpacesItem.state = WindowOverlay.pinToAllSpaces ? .on : .off
        menu.addItem(allSpacesItem)

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

    @objc private func setCaptureRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(rate, forKey: "captureRate")
        tracker.updateCaptureRate()
        wplog("setCaptureRate: \(rate) fps")
    }

    @objc private func toggleAllSpaces() {
        let newValue = !WindowOverlay.pinToAllSpaces
        UserDefaults.standard.set(newValue, forKey: "pinToAllSpaces")
        tracker.updateAllSpaces()
        wplog("toggleAllSpaces: \(newValue)")
    }

    @objc private func quit() {
        tracker.unpinAll()
        NSApp.terminate(nil)
    }

    // MARK: - Global hotkey (CGEvent tap)

    private func registerHotkey() {
        _hotkeyAction = { [weak self] in
            self?.togglePinFrontmostWindow()
        }
        _shortcutKeyCode = Int64(shortcutKeyCode)
        _shortcutCGModifiers = nsToCGModifiers(shortcutModifiers)

        if !tryCreateEventTap() {
            // Permission not yet granted — poll until it is
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
        // Don't create a second tap
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

    private func saveShortcut() {
        UserDefaults.standard.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode")
        UserDefaults.standard.set(Int(shortcutModifiers.rawValue), forKey: "shortcutModifiers")

        // Update the CGEvent tap globals
        _shortcutKeyCode = Int64(shortcutKeyCode)
        _shortcutCGModifiers = nsToCGModifiers(shortcutModifiers)
    }

    @objc private func changeShortcut() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Record Shortcut"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        let label = NSTextField(labelWithString: "Press your desired key combination…")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 30, width: 280, height: 30)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        container.addSubview(label)
        panel.contentView = container

        // Use a local event monitor to capture the next key press
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Require at least one modifier key
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                return event
            }

            // Escape cancels
            if event.keyCode == 53 {
                if let m = monitor { NSEvent.removeMonitor(m) }
                panel.close()
                return nil
            }

            self.shortcutKeyCode = event.keyCode
            self.shortcutModifiers = flags.intersection([.command, .control, .option, .shift])
            self.saveShortcut()

            wplog("changeShortcut: new shortcut keyCode=\(event.keyCode) mods=\(flags.rawValue) display=\(self.shortcutDisplayString())")

            if let m = monitor { NSEvent.removeMonitor(m) }
            panel.close()
            return nil
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func shortcutDisplayString() -> String {
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

    // MARK: - About

    @objc private func openAbout() {
        guard let button = statusItem.button else { return }
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = true
        let hc = NSHostingController(rootView: AboutView(appName: "WindowPin", onDismiss: { [weak self] in self?.closeAbout() }))
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        p.contentViewController = hc
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        aboutPopover = p
        aboutMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeAbout()
        }
    }

    private func closeAbout() {
        aboutPopover?.performClose(nil)
        aboutPopover = nil
        if let m = aboutMonitor { NSEvent.removeMonitor(m); aboutMonitor = nil }
    }

    // MARK: - Helpers

    private func truncate(_ s: String, max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }
}
