import AppKit

struct PinnedWindow: Hashable {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String

    /// Display label for the menu: "Safari — GitHub" or "Terminal" if no title.
    var displayLabel: String {
        if windowTitle.isEmpty {
            return ownerName
        }
        let maxLen = 40
        let title = windowTitle.count > maxLen
            ? String(windowTitle.prefix(maxLen)) + "…"
            : windowTitle
        return "\(ownerName) — \(title)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: PinnedWindow, rhs: PinnedWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

final class PinnedWindowTracker {

    private(set) var pinnedWindows: Set<PinnedWindow> = []
    private var overlays: [UInt32: WindowOverlay] = [:]
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    /// Called whenever the pinned set changes.
    var onChange: (() -> Void)?

    init() {
        startPolling()
        observeAppActivation()
        observeAppTermination()
    }

    deinit {
        pollTimer?.invalidate()
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Public API

    func isPinned(windowID: UInt32) -> Bool {
        pinnedWindows.contains(where: { $0.windowID == windowID })
    }

    func pin(window: ForeignWindow) {
        let pw = PinnedWindow(
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            ownerName: window.ownerName,
            windowTitle: window.windowTitle
        )
        guard !pinnedWindows.contains(pw) else { return }

        pinnedWindows.insert(pw)

        // Always create the overlay — if Screen Recording isn't granted,
        // the capture will just return nil and the overlay stays blank.
        let overlay = WindowOverlay(
            windowID: CGWindowID(window.windowID),
            pid: window.ownerPID
        )
        overlays[window.windowID] = overlay
        wplog("pin: overlay created for wid=\(window.windowID)")

        onChange?()
    }

    func unpin(windowID: UInt32) {
        guard let pw = pinnedWindows.first(where: { $0.windowID == windowID }) else { return }
        overlays[windowID]?.hideOverlay()
        overlays[windowID] = nil
        pinnedWindows.remove(pw)
        onChange?()
    }

    func unpinAll() {
        for (_, overlay) in overlays {
            overlay.hideOverlay()
        }
        overlays.removeAll()
        pinnedWindows.removeAll()
        onChange?()
    }

    func updateCaptureRate() {
        for (_, overlay) in overlays {
            overlay.applyCaptureRate()
        }
    }

    func updateAllSpaces() {
        for (_, overlay) in overlays {
            overlay.updateCollectionBehavior()
        }
    }

    func toggle(window: ForeignWindow) {
        if isPinned(windowID: window.windowID) {
            unpin(windowID: window.windowID)
        } else {
            pin(window: window)
        }
    }

    // MARK: - App activation observer

    private func observeAppActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, !self.pinnedWindows.isEmpty else { return }

            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let activatedPID = app.processIdentifier
            let myPID = ProcessInfo.processInfo.processIdentifier
            guard activatedPID != myPID else { return }

            // For each pinned window:
            // - If the activated app owns this window → drop overlay behind (user is using real window)
            // - Otherwise → raise overlay to front (user switched away, keep pinned content visible)
            for pw in self.pinnedWindows {
                if let overlay = self.overlays[pw.windowID] {
                    if pw.ownerPID == activatedPID {
                        overlay.sendBehind()
                    } else {
                        overlay.bringToFront()
                    }
                }
            }
        }
    }

    // MARK: - Polling for closed windows

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pruneClosedWindows()
        }
    }

    private func pruneClosedWindows() {
        guard !pinnedWindows.isEmpty else { return }
        let onScreen = WindowDetector.allOnScreenWindowIDs()
        let removed = pinnedWindows.filter { !onScreen.contains($0.windowID) }
        guard !removed.isEmpty else { return }
        for pw in removed {
            overlays[pw.windowID]?.hideOverlay()
            overlays[pw.windowID] = nil
            pinnedWindows.remove(pw)
        }
        onChange?()
    }

    // MARK: - App termination

    private func observeAppTermination() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let removed = self.pinnedWindows.filter { $0.ownerPID == pid }
            guard !removed.isEmpty else { return }
            for pw in removed {
                self.overlays[pw.windowID]?.hideOverlay()
                self.overlays[pw.windowID] = nil
                self.pinnedWindows.remove(pw)
            }
            self.onChange?()
        }
    }
}
