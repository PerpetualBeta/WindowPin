import AppKit
import ScreenCaptureKit

/// A floating panel that captures and displays a foreign window's content.
/// Acts as a live "picture-in-picture" view that stays on top of all windows.
///
/// Instead of hiding/showing (which causes flicker), the overlay stays on-screen
/// at all times and toggles between z-levels:
///   - `.floating` when the user is in another app (overlay visible above everything)
///   - below normal when the user is using the real window (overlay hidden behind it)
class WindowOverlay: NSPanel {

    let targetWindowID: CGWindowID
    let targetPID: pid_t
    private var captureTimer: Timer?
    private let imageView: NSImageView
    private var scWindow: SCWindow?

    /// Whether the overlay is currently in "pinned visible" mode.
    private(set) var isPinVisible = false

    /// Capture rate in frames per second (configurable via UserDefaults "captureRate", default 1).
    static var captureRate: Double {
        let stored = UserDefaults.standard.double(forKey: "captureRate")
        return stored > 0 ? stored : 1.0
    }

    /// Whether pinned overlays appear on all Mission Control spaces.
    static var pinToAllSpaces: Bool {
        UserDefaults.standard.bool(forKey: "pinToAllSpaces")
    }

    init(windowID: CGWindowID, pid: pid_t) {
        targetWindowID = windowID
        targetPID = pid
        imageView = NSImageView()

        let frame = Self.getWindowFrame(windowID: windowID)
            ?? NSRect(x: 100, y: 100, width: 800, height: 600)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = Self.pinToAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]

        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        imageView.autoresizingMask = [.width, .height]
        contentView = imageView

        // Resolve the SCWindow asynchronously
        resolveSCWindow()
    }

    // MARK: - ScreenCaptureKit window resolution

    private func resolveSCWindow() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )
                if let match = content.windows.first(where: { $0.windowID == targetWindowID }) {
                    self.scWindow = match
                    wplog("overlay: resolved SCWindow for wid=\(targetWindowID) title='\(match.title ?? "")'")
                } else {
                    wplog("overlay: SCWindow NOT FOUND for wid=\(targetWindowID) (checked \(content.windows.count) windows)")
                }
            } catch {
                wplog("overlay: SCShareableContent error: \(error)")
            }
        }
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        wplog("overlay: clicked wid=\(targetWindowID), activating actual window")

        // Drop overlay behind the real window, then raise the real window on top
        sendBehind()
        WindowLevelManager.raiseWindow(pid: self.targetPID, windowID: UInt32(self.targetWindowID))
    }

    // MARK: - Z-level transitions (no hide/show, just level changes)

    /// Make overlay visible above all windows. Captures a fresh frame first if possible.
    func bringToFront() {
        guard !isPinVisible else {
            wplog("overlay: bringToFront skipped (already front) wid=\(targetWindowID)")
            return
        }
        wplog("overlay: bringToFront wid=\(targetWindowID)")
        isPinVisible = true
        updateFrameFromTarget()

        if !isVisible {
            // First time — need to put on screen and start capturing
            doInitialShow()
            return
        }

        // Already on screen but behind — just raise level
        level = .floating
        orderFront(nil)
        startCapturing()
    }

    /// Drop overlay behind all normal windows (invisible to user, but still on-screen).
    func sendBehind() {
        guard isPinVisible else { return }
        wplog("overlay: sendBehind wid=\(targetWindowID)")
        isPinVisible = false
        stopCapturing()
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        orderBack(nil)
    }

    /// Fully remove overlay from screen (used when unpinning / cleaning up).
    func hideOverlay() {
        wplog("overlay: hideOverlay wid=\(targetWindowID)")
        isPinVisible = false
        stopCapturing()
        orderOut(nil)
    }

    // MARK: - Initial show (first time only)

    private func doInitialShow() {
        guard let scWindow = self.scWindow else {
            // SCWindow not resolved yet — show immediately, capture will fill in
            level = .floating
            alphaValue = 0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.animator().alphaValue = 1
            }
            startCapturing()
            return
        }

        // Capture a fresh frame BEFORE showing so first visible frame has content
        Task {
            do {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = self.makeCaptureConfig()
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                let nsImage = NSImage(
                    cgImage: image,
                    size: NSSize(width: self.frame.width, height: self.frame.height)
                )
                await MainActor.run {
                    self.imageView.image = nsImage
                    self.fadeIn()
                }
            } catch {
                wplog("overlay: pre-show capture failed wid=\(targetWindowID): \(error)")
                await MainActor.run {
                    self.fadeIn()
                }
            }
        }
    }

    private func fadeIn() {
        level = .floating
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1
        }
        startCapturing()
    }

    // MARK: - Capture loop

    private func startCapturing() {
        captureTimer?.invalidate()
        let interval = 1.0 / Self.captureRate
        captureTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.captureAndDisplay()
        }
    }

    private func stopCapturing() {
        captureTimer?.invalidate()
        captureTimer = nil
    }

    func restartCapturing() {
        if isPinVisible {
            stopCapturing()
            startCapturing()
        }
    }

    func updateCollectionBehavior() {
        collectionBehavior = Self.pinToAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
    }

    private func captureAndDisplay() {
        updateFrameFromTarget()

        guard let scWindow = self.scWindow else {
            wplog("overlay: capture skipped — SCWindow not yet resolved for wid=\(targetWindowID)")
            resolveSCWindow()
            return
        }

        Task {
            do {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = self.makeCaptureConfig()

                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )

                let nsImage = NSImage(
                    cgImage: image,
                    size: NSSize(width: self.frame.width, height: self.frame.height)
                )

                await MainActor.run {
                    self.imageView.image = nsImage
                }
            } catch {
                wplog("overlay: SCScreenshotManager.captureImage error wid=\(targetWindowID): \(error)")
            }
        }
    }

    private func makeCaptureConfig() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(self.frame.width * 2)   // Retina
        config.height = Int(self.frame.height * 2)
        config.scalesToFit = true
        config.showsCursor = false
        return config
    }

    private func updateFrameFromTarget() {
        guard let frame = Self.getWindowFrame(windowID: targetWindowID) else { return }
        if self.frame != frame {
            setFrame(frame, display: false)
        }
    }

    // MARK: - Coordinate conversion (CG top-left → NS bottom-left)

    static func getWindowFrame(windowID: CGWindowID) -> NSRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let entry = info.first,
              let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }

        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0
        let w = bounds["Width"] ?? 0
        let h = bounds["Height"] ?? 0

        let screenHeight = NSScreen.screens[0].frame.height
        let nsY = screenHeight - y - h

        return NSRect(x: x, y: nsY, width: w, height: h)
    }

    deinit {
        stopCapturing()
    }
}
