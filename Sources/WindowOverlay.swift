import AppKit
import CoreMedia
import ScreenCaptureKit

/// A floating panel that mirrors a foreign window's content via a live
/// ScreenCaptureKit stream. Acts as a live "picture-in-picture" view that
/// stays on top of all windows.
///
/// Instead of hiding/showing (which causes flicker), the overlay stays on-screen
/// at all times and toggles between z-levels:
///   - `.floating` when the user is in another app (overlay visible above everything)
///   - below normal when the user is using the real window (overlay hidden behind it)
///
/// The stream only runs while the overlay is front — frames arrive only when
/// the window's content actually changes, and stopping the stream while the
/// overlay is hidden keeps the system's "screen recording" indicator away.
///
/// While the overlay is front, clicks and scrolls on it are forwarded to the
/// real window (see EventForwarder), so the pinned window can be scrolled and
/// clicked without switching apps. ⌘-click switches to the real window.
class WindowOverlay: NSPanel {

    let targetWindowID: CGWindowID
    let targetPID: pid_t

    private let contentLayer = CALayer()
    private var scWindow: SCWindow?
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "cc.jorviksoftware.WindowPin.frames")
    /// Retains the pixel buffer whose IOSurface the layer currently displays,
    /// so ScreenCaptureKit can't recycle it out from under the layer.
    private var displayedFrame: CVPixelBuffer?
    private var frameSyncTimer: Timer?
    private var lastStreamSize: CGSize = .zero
    /// Points→pixels scale of the capture, taken from the content filter.
    private var streamPixelScale: CGFloat = 2
    private var didLogFirstFrame = false
    /// Total frames delivered by the stream (diagnostics).
    private(set) var framesReceived = 0

    /// Whether the overlay is currently in "pinned visible" mode.
    private(set) var isPinVisible = false

    /// Maximum stream frame rate (configurable via UserDefaults "captureRate", default 30).
    /// The stream only delivers frames when the window content changes, so a
    /// high cap costs nothing for static content.
    static var captureRate: Double {
        let stored = UserDefaults.standard.double(forKey: "captureRate")
        return stored > 0 ? stored : 30.0
    }

    /// Whether pinned overlays appear on all Mission Control spaces.
    static var pinToAllSpaces: Bool {
        UserDefaults.standard.bool(forKey: "pinToAllSpaces")
    }

    /// Whether clicks/scrolls on an overlay are forwarded to the real window.
    static var forwardEvents: Bool {
        UserDefaults.standard.object(forKey: "forwardEvents") as? Bool ?? true
    }

    init(windowID: CGWindowID, pid: pid_t) {
        targetWindowID = windowID
        targetPID = pid

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

        // Layer-hosting view: frames land straight on the layer as IOSurfaces,
        // no NSImage conversion.
        contentLayer.contentsGravity = .resize
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.layer = contentLayer
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        contentView = view

        // Resolve the SCWindow asynchronously
        resolveSCWindow()
    }

    // MARK: - ScreenCaptureKit window resolution

    private func resolveSCWindow(thenStartStream: Bool = false) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )
                if let match = content.windows.first(where: { $0.windowID == targetWindowID }) {
                    self.scWindow = match
                    wplog("overlay: resolved SCWindow for wid=\(targetWindowID) title='\(match.title ?? "")'")
                    if thenStartStream && self.isPinVisible {
                        self.startStream()
                    }
                } else {
                    wplog("overlay: SCWindow NOT FOUND for wid=\(targetWindowID) (checked \(content.windows.count) windows)")
                    scheduleResolveRetry(thenStartStream: thenStartStream)
                }
            } catch {
                wplog("overlay: SCShareableContent error: \(error)")
                scheduleResolveRetry(thenStartStream: thenStartStream)
            }
        }
    }

    private func scheduleResolveRetry(thenStartStream: Bool) {
        guard thenStartStream else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.isPinVisible, self.stream == nil else { return }
            self.resolveSCWindow(thenStartStream: true)
        }
    }

    // MARK: - Event handling

    override func sendEvent(_ event: NSEvent) {
        guard isPinVisible, Self.forwardEvents else {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.command):
            // Escape hatch: ⌘-click switches to the real window.
            activateRealWindow()
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel:
            EventForwarder.forward(event, from: self)
        default:
            super.sendEvent(event)
        }
    }

    /// Fallback when event forwarding is disabled: any click switches to the
    /// real window (the pre-forwarding behaviour).
    override func mouseDown(with event: NSEvent) {
        activateRealWindow()
    }

    private func activateRealWindow() {
        wplog("overlay: switching to real window wid=\(targetWindowID)")
        sendBehind()
        WindowLevelManager.raiseWindow(pid: targetPID, windowID: UInt32(targetWindowID))
    }

    // MARK: - Z-level transitions (no hide/show, just level changes)

    /// Make overlay visible above all windows and start the live stream.
    func bringToFront() {
        guard !isPinVisible else {
            wplog("overlay: bringToFront skipped (already front) wid=\(targetWindowID)")
            return
        }
        wplog("overlay: bringToFront wid=\(targetWindowID)")
        isPinVisible = true
        syncFrameWithTarget()

        if !isVisible {
            // First time — need to put on screen with content already in place
            doInitialShow()
            return
        }

        // Already on screen but behind — just raise level. The last streamed
        // frame is still on the layer, so there's content until fresh frames land.
        level = .floating
        orderFront(nil)
        startStream()
        startFrameSync()
    }

    /// Drop overlay behind all normal windows (invisible to user, but still on-screen).
    func sendBehind() {
        guard isPinVisible else { return }
        wplog("overlay: sendBehind wid=\(targetWindowID)")
        isPinVisible = false
        stopStream()
        stopFrameSync()
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        orderBack(nil)
    }

    /// Fully remove overlay from screen (used when unpinning / cleaning up).
    func hideOverlay() {
        wplog("overlay: hideOverlay wid=\(targetWindowID)")
        isPinVisible = false
        stopStream()
        stopFrameSync()
        orderOut(nil)
    }

    // MARK: - Initial show (first time only)

    private func doInitialShow() {
        guard let scWindow = self.scWindow else {
            // SCWindow not resolved yet — show immediately, stream will fill in
            fadeIn()
            return
        }

        // Grab one screenshot BEFORE showing so the first visible frame has
        // content — the stream takes a beat to deliver its first frame.
        Task {
            do {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = self.makeStreamConfig(pixelScale: CGFloat(filter.pointPixelScale))
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                await MainActor.run {
                    self.contentLayer.contents = image
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
        startStream()
        startFrameSync()
    }

    // MARK: - Live stream

    private func startStream() {
        guard stream == nil else { return }
        guard let scWindow = self.scWindow else {
            resolveSCWindow(thenStartStream: true)
            return
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        // Capture at the window's true native scale: 1:1 pixels need no
        // resampling at composite time, which is what keeps text sharp.
        let filterScale = CGFloat(filter.pointPixelScale)
        streamPixelScale = filterScale >= 1 ? filterScale : displayScale
        let config = makeStreamConfig(pixelScale: streamPixelScale)
        lastStreamSize = frame.size
        didLogFirstFrame = false
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            wplog("overlay: addStreamOutput failed wid=\(targetWindowID): \(error)")
            return
        }
        stream = newStream
        newStream.startCapture { [weak self] error in
            guard let error = error else { return }
            wplog("overlay: startCapture failed wid=\(self?.targetWindowID ?? 0): \(error)")
            DispatchQueue.main.async {
                if self?.stream === newStream { self?.stream = nil }
            }
        }
        wplog("overlay: stream starting wid=\(targetWindowID) maxFPS=\(Self.captureRate)")
    }

    private func stopStream() {
        guard let stream = stream else { return }
        self.stream = nil
        stream.stopCapture { error in
            if let error = error {
                wplog("overlay: stopCapture error: \(error)")
            }
        }
    }

    /// Apply the current capture-rate setting / frame size to a running stream.
    func applyCaptureRate() {
        guard let stream = stream else { return }
        stream.updateConfiguration(makeStreamConfig(pixelScale: streamPixelScale)) { error in
            if let error = error {
                wplog("overlay: updateConfiguration (rate) error: \(error)")
            }
        }
    }

    func updateCollectionBehavior() {
        collectionBehavior = Self.pinToAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
    }

    /// Backing scale of the screen the overlay (or its target frame) is on.
    private var displayScale: CGFloat {
        if let screen = screen { return screen.backingScaleFactor }
        let f = frame
        if let match = NSScreen.screens.first(where: { $0.frame.intersects(f) }) {
            return match.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func makeStreamConfig(pixelScale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Size the output to the window's native pixels and pin the resolution
        // to .best — .automatic can deliver nominal (1x) frames that end up
        // stretched over a Retina layer, which reads as a slightly blurred pin.
        config.width = max(Int(frame.width * pixelScale), 1)
        config.height = max(Int(frame.height * pixelScale), 1)
        config.captureResolution = .best
        config.scalesToFit = true
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(
            seconds: 1.0 / max(Self.captureRate, 0.1),
            preferredTimescale: 600
        )
        return config
    }

    // MARK: - Frame sync (follow the target window while visible)

    private func startFrameSync() {
        frameSyncTimer?.invalidate()
        frameSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncFrameWithTarget()
        }
    }

    private func stopFrameSync() {
        frameSyncTimer?.invalidate()
        frameSyncTimer = nil
    }

    private func syncFrameWithTarget() {
        guard let target = Self.getWindowFrame(windowID: targetWindowID) else { return }
        if frame != target {
            setFrame(target, display: false)
        }
        // Window resized → the stream's output size needs to follow.
        if stream != nil,
           abs(target.width - lastStreamSize.width) > 1 || abs(target.height - lastStreamSize.height) > 1 {
            lastStreamSize = target.size
            applyCaptureRate()
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
        frameSyncTimer?.invalidate()
        if let stream = stream {
            stream.stopCapture { _ in }
        }
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension WindowOverlay: SCStreamOutput, SCStreamDelegate {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer) else { return }

        let surfaceRef = surface.takeUnretainedValue()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.framesReceived += 1
            if !self.didLogFirstFrame {
                self.didLogFirstFrame = true
                wplog("overlay: first frame \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))px for \(Int(self.frame.width))x\(Int(self.frame.height))pt @\(self.streamPixelScale)x wid=\(self.targetWindowID)")
            }
            self.displayedFrame = pixelBuffer
            self.contentLayer.contents = surfaceRef
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        wplog("overlay: stream stopped wid=\(targetWindowID): \(error)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.stream === stream { self.stream = nil }
            // Window may have closed (tracker will prune it), or capture broke
            // (display reconfigure) — retry while we're still pinned-visible.
            if self.isPinVisible {
                self.resolveSCWindow(thenStartStream: true)
            }
        }
    }
}
