import AppKit
import CoreMedia
import ScreenCaptureKit

/// The window number behind an Accessibility window element. Private, but
/// unchanged for many macOS releases and relied on by window managers that
/// need to join the two worlds; there is no public equivalent.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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
///
/// Option-drag crops the overlay to part of the window (see `crop`). A cropped
/// overlay is a small panel of its own: it can be dragged anywhere, resized by
/// its edges to show more or less of the window, and it
/// stays up while other windows of the same app are in use.
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
    /// The part of the window the running stream was configured for, so a
    /// resize or a new crop can tell whether the stream needs reconfiguring.
    private var lastStreamGeometry: CGRect = .zero

    /// The part of the target window this pin shows, in points from the
    /// window's top-left corner. nil shows the whole window.
    ///
    /// Option-drag on a pin draws it; option-click on a cropped pin clears it.
    /// It is a fixed area of the window, so content that scrolls or reflows
    /// can move out of it. Moving the window is fine: the crop moves with it.
    private(set) var crop: CGRect?
    /// Where the user dragged a cropped pin to. nil keeps the pin over the
    /// area of the window it shows, following the window as it moves.
    private var movedOrigin: NSPoint?
    var isCropped: Bool { crop != nil }

    /// Called when a crop is set or cleared, so the tracker can start or stop
    /// deciding this pin's layering window by window. See `isTargetInUse`.
    var onCropChange: (() -> Void)?

    /// Option-drag in progress: where it started, in the panel's own points.
    private var selectionStart: NSPoint?
    private let selectionShade = CAShapeLayer()
    private let selectionBorder = CAShapeLayer()
    /// Plain drag on a cropped pin in progress: the pointer and the panel
    /// origin when it started, both in screen points.
    private var moveStart: (pointer: NSPoint, origin: NSPoint)?
    private var didMove = false
    /// Set by `mouseDown(with:)` when a press on a cropped pin reaches the
    /// content, meaning AppKit did not take it as a resize.
    private var pressReachedContent = false
    /// A press AppKit took (a resize) is in progress; its drags and release
    /// go to AppKit too.
    private var systemPressInProgress = false
    /// True while WindowPin itself is setting the panel's frame, so that the
    /// resize observer only reacts to the user resizing a cropped pin.
    private var applyingFrame = false
    /// The panel's frame after the last change that was accounted for, so a
    /// resize can tell which edges moved and by how much.
    private var lastPanelFrame: NSRect = .zero
    /// A selection smaller than this either way is taken as a click, not a
    /// crop. It is also about as small as a pin can usefully be.
    private static let minimumCropSide: CGFloat = 16
    /// How far a plain press on a cropped pin must travel to be a move rather
    /// than a click. AppKit's own drag threshold is of the same order.
    private static let moveThreshold: CGFloat = 3
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
    /// Forward clicks and scrolls into the pinned window.
    ///
    /// **Defaults to off on macOS 27 and later.** Forwarding posts a synthetic
    /// CGEvent to the target process. Measured 2026-09-23 on 27.0 (26A428) with
    /// a purpose-built receiver app: the events arrive and bind to the correct
    /// window, but their location is always the window's top-left corner, so
    /// AppKit hit-tests the corner, finds no view and drops every one. Stamping
    /// the window resets the location; not stamping it leaves no window bound;
    /// no integer field carries the location (all 153 were tested); copying a
    /// real event does not help, nor does write ordering. The window server
    /// derives that location itself and will not take ours.
    ///
    /// Leaving it on there makes every click a silent no-op. Off, a click does
    /// the obvious thing and takes you to the real window. Earlier releases are
    /// unaffected and keep the old default.
    static var forwardEvents: Bool {
        if let stored = UserDefaults.standard.object(forKey: "forwardEvents") as? Bool {
            return stored
        }
        if #available(macOS 27, *) { return false }
        return true
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

        // The option-drag selection: the outside is shaded, the inside left
        // clear, with a dashed edge. Sublayers survive each frame replacing
        // the content layer's contents.
        selectionShade.fillRule = .evenOdd
        selectionShade.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        selectionBorder.fillColor = nil
        selectionBorder.strokeColor = NSColor.white.cgColor
        selectionBorder.lineWidth = 1.5
        selectionBorder.lineDashPattern = [6, 4]
        selectionBorder.shadowColor = NSColor.black.cgColor
        selectionBorder.shadowOpacity = 0.8
        selectionBorder.shadowRadius = 1
        selectionBorder.shadowOffset = .zero
        for layer in [selectionShade, selectionBorder] {
            layer.isHidden = true
            layer.actions = ["path": NSNull(), "hidden": NSNull()]
            contentLayer.addSublayer(layer)
        }

        // Resolve the SCWindow asynchronously
        resolveSCWindow()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            self?.cropFollowsResize()
        }
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

    /// Drive the pinned window through Accessibility instead of forwarding
    /// events to it. macOS 27 only.
    ///
    /// On 27 a posted CGEvent cannot be placed inside another app's window —
    /// see `forwardEvents` — so scrolling a pin had simply stopped working.
    /// Setting the target's scroll position directly does work, and was
    /// measured on 2026-09-23 to scroll a background, occluded Finder window
    /// three times running without the frontmost app changing.
    ///
    /// Scroll only. There is no equivalent for a click: pressing a button
    /// through Accessibility would activate something the user only pointed
    /// at, so a click still takes you to the real window, which is the
    /// behaviour Jonathan said he prefers anyway.
    /// The target window's bounds in global top-left coordinates.
    static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let b = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                      width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    }

    private var usesAccessibilityScrolling: Bool {
        if #available(macOS 27, *) {
            // The same switch the user already knows, "Interact through
            // overlays". On 27 that means scrolling, since clicking now always
            // hands over. A second hidden knob would only be a way to get the
            // two out of step.
            return Self.forwardEvents
        }
        return false
    }

    /// The point in the target window under a point on the overlay, in global
    /// top-left coordinates. The overlay shows either the whole window or its
    /// crop, scaled to the panel: take the fraction across the panel and apply
    /// it to the part of the window being shown. Fractions rather than offsets
    /// keep the point right while the two frames briefly disagree mid-resize.
    func targetPoint(forLocation loc: NSPoint) -> CGPoint? {
        let size = frame.size
        guard size.width > 0, size.height > 0,
              let bounds = Self.windowBounds(targetWindowID) else { return nil }
        let fx = loc.x / size.width
        let fyFromTop = (size.height - loc.y) / size.height
        guard fx >= 0, fx <= 1, fyFromTop >= 0, fyFromTop <= 1 else { return nil }
        let shown = shownRect(windowSize: bounds.size)
        return CGPoint(x: bounds.origin.x + shown.minX + fx * shown.width,
                       y: bounds.origin.y + shown.minY + fyFromTop * shown.height)
    }

    /// The part of the window on show, in points from its top-left corner.
    private func shownRect(windowSize: CGSize) -> CGRect {
        clampedCrop(windowSize: windowSize) ?? CGRect(origin: .zero, size: windowSize)
    }

    /// The crop, trimmed to the window as it is now. A window made smaller than
    /// its crop shows what is left of it; one that loses the area entirely
    /// keeps the original rectangle, so the pin keeps its size and shows the
    /// window's edge rather than collapsing to nothing.
    private func clampedCrop(windowSize: CGSize) -> CGRect? {
        guard let crop else { return nil }
        let trimmed = crop.intersection(CGRect(origin: .zero, size: windowSize))
        return trimmed.isNull || trimmed.width < 1 || trimmed.height < 1 ? crop : trimmed
    }

    override func sendEvent(_ event: NSEvent) {
        if isPinVisible, handleCropGesture(event) { return }

        if event.type == .scrollWheel, isPinVisible, usesAccessibilityScrolling {
            if let point = targetPoint(forLocation: event.locationInWindow) {
                AXScroller.scroll(pid: targetPID, windowID: targetWindowID,
                                  deltaY: event.scrollingDeltaY, at: point)
            }
            return
        }
        // macOS 27: a click never goes to the forwarder, whatever the setting
        // says. Forwarding cannot place an event inside another app's window
        // there, so routing a click into it makes the click silently do
        // nothing — which is what happened when this was left to a DEFAULT: a
        // value already stored on the machine beat the new default and the
        // click disappeared. Taking the user to the real window is the honest
        // response, and it is the behaviour Jonathan asked for.
        if #available(macOS 27, *), isPinVisible {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                activateRealWindow()
                return
            case .leftMouseUp, .leftMouseDragged, .rightMouseUp, .rightMouseDragged,
                 .otherMouseUp, .otherMouseDragged:
                return      // the down already handed over; swallow the rest
            default:
                break
            }
        }

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
        // A cropped pin sends presses through AppKit to find out whether they
        // are a resize; one that arrives here was not, and is handled by
        // `handleCropGesture` as a move or a click.
        if isCropped {
            pressReachedContent = true
            return
        }
        activateRealWindow()
    }

    /// A cropped pin is a titled window, which AppKit would otherwise let
    /// become key on a click. The pin must never take the keyboard from the
    /// app being worked in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func activateRealWindow() {
        wplog("overlay: switching to real window wid=\(targetWindowID)")
        sendBehind()
        // Explicitly activating: this is the deliberate "take me to the real
        // window" action, the one place where moving focus is the point.
        WindowLevelManager.raiseWindow(pid: targetPID, windowID: UInt32(targetWindowID), activate: true)
    }

    // MARK: - Cropping

    /// Option-drag selects an area to crop to; option-click on a cropped pin
    /// shows the whole window again. On a cropped pin a plain drag moves it and
    /// a plain click still hands over to the real window. Returns whether the
    /// event was used.
    ///
    /// This runs before forwarding, on every macOS: a cropped pin is small and
    /// sits wherever the user put it, so moving it has to be possible, and an
    /// option-drag is no longer passed to the pinned app on macOS 26 and earlier.
    private func handleCropGesture(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.option):
            selectionStart = event.locationInWindow
            showSelection(to: event.locationInWindow)
            return true
        case .leftMouseDragged where selectionStart != nil:
            showSelection(to: event.locationInWindow)
            return true
        case .leftMouseUp where selectionStart != nil:
            finishSelection(at: event.locationInWindow)
            return true

        case .leftMouseDown where isCropped:
            // macOS decides whether a press is on the window's resize edge;
            // there is no public way to ask where that edge is. So the press
            // goes to AppKit first. A press anywhere but the edge reaches the
            // content and lands in `mouseDown(with:)`, which marks it as ours
            // to move or click. One on the edge starts a resize, which AppKit
            // carries on through the drags that follow (measured on 27.0.1:
            // this call returns at once, before any of them).
            pressReachedContent = false
            super.sendEvent(event)
            if pressReachedContent {
                moveStart = (NSEvent.mouseLocation, frame.origin)
                didMove = false
            } else {
                // AppKit took the press as a resize. It carries the resize on
                // through the drags that follow, so they must reach it.
                systemPressInProgress = true
            }
            return true
        case .leftMouseDragged where systemPressInProgress:
            super.sendEvent(event)
            return true
        case .leftMouseUp where systemPressInProgress:
            systemPressInProgress = false
            super.sendEvent(event)
            return true
        case .leftMouseDragged where moveStart != nil:
            guard let start = moveStart else { return true }
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - start.pointer.x, dy = pointer.y - start.pointer.y
            if didMove || hypot(dx, dy) >= Self.moveThreshold {
                didMove = true
                let origin = NSPoint(x: start.origin.x + dx, y: start.origin.y + dy)
                movedOrigin = origin
                setFrameOrigin(origin)
                lastPanelFrame = frame
            }
            return true
        case .leftMouseUp where moveStart != nil:
            moveStart = nil
            if !didMove { activateRealWindow() }
            return true

        default:
            return false
        }
    }

    /// The selection from where the option-drag started to `point`, both in
    /// the panel's points, limited to the panel.
    private func selectionRect(to point: NSPoint) -> CGRect? {
        guard let start = selectionStart else { return nil }
        let panel = CGRect(origin: .zero, size: frame.size)
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        return rect.intersection(panel)
    }

    private func showSelection(to point: NSPoint) {
        let panel = CGRect(origin: .zero, size: frame.size)
        let rect = selectionRect(to: point) ?? .zero
        let scale = backingScaleFactor
        let shade = CGMutablePath()
        shade.addRect(panel)
        shade.addRect(rect)
        for layer in [selectionShade, selectionBorder] {
            layer.frame = panel
            layer.contentsScale = scale
            layer.isHidden = false
        }
        selectionShade.path = shade
        // Inset by half the line so the edge is drawn inside the selection
        // and stays visible when it runs along the panel's edge.
        selectionBorder.path = CGPath(rect: rect.insetBy(dx: 0.75, dy: 0.75), transform: nil)
    }

    private func finishSelection(at point: NSPoint) {
        let rect = selectionRect(to: point)
        selectionStart = nil
        selectionShade.isHidden = true
        selectionBorder.isHidden = true

        guard let rect, !rect.isNull,
              rect.width >= Self.minimumCropSide, rect.height >= Self.minimumCropSide else {
            // An option-click, or a selection too small to be one.
            if isCropped { setCrop(nil) }
            return
        }
        guard let windowSize = Self.windowBounds(targetWindowID)?.size,
              frame.width > 0, frame.height > 0 else { return }

        // Panel points (bottom-left origin) to window points (top-left
        // origin), through whatever is on show now, so cropping a cropped pin
        // narrows it further.
        let shown = shownRect(windowSize: windowSize)
        let sx = shown.width / frame.width, sy = shown.height / frame.height
        let windowRect = CGRect(x: shown.minX + rect.minX * sx,
                                y: shown.minY + (frame.height - rect.maxY) * sy,
                                width: rect.width * sx, height: rect.height * sy).integral
        setCrop(windowRect)
    }

    private func setCrop(_ newCrop: CGRect?) {
        if let windowSize = Self.windowBounds(targetWindowID)?.size {
            showLastFrame(from: shownRect(windowSize: windowSize),
                          to: newCrop.map { $0.intersection(CGRect(origin: .zero, size: windowSize)) }
                              ?? CGRect(origin: .zero, size: windowSize))
        }
        crop = newCrop
        movedOrigin = nil
        if let newCrop {
            wplog("overlay: crop wid=\(targetWindowID) to \(Int(newCrop.minX)),\(Int(newCrop.minY)) \(Int(newCrop.width))x\(Int(newCrop.height))pt")
        } else {
            wplog("overlay: crop cleared wid=\(targetWindowID)")
        }
        // Changing the style can resize the panel, which must not be read as
        // the user resizing the new crop.
        applyingFrame = true
        applyWindowStyle()
        applyingFrame = false
        syncFrameWithTarget()
        onCropChange?()
    }

    /// A cropped pin looks like a window of its own, so it gets the system's
    /// window corners and edge. Neither has a public value to copy, so the pin
    /// becomes a titled window with an invisible title bar and macOS draws
    /// them, whatever the current release uses. A whole-window pin stays
    /// borderless: the window it shows already has its own corners.
    ///
    /// Moving is left to `handleCropGesture`, so the title bar must not move
    /// the window itself.
    private func applyWindowStyle() {
        let framed: NSWindow.StyleMask = [.titled, .fullSizeContentView, .resizable]
        let wanted = isCropped
        guard styleMask.isSuperset(of: framed) != wanted else { return }
        if wanted {
            styleMask.formUnion(framed)
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                standardWindowButton(button)?.isHidden = true
            }
            isMovable = false
            contentMinSize = NSSize(width: Self.minimumCropSide, height: Self.minimumCropSide)
        } else {
            styleMask.subtract(framed)
        }
    }

    /// The user resized a cropped pin by one of its edges or corners. The crop
    /// moves the same edges by the same amount, so the pin shows more or less
    /// of the window around what it showed before, at the same scale. A crop
    /// cannot grow past the window, so the panel is trimmed back to it.
    private func cropFollowsResize() {
        guard isCropped, !applyingFrame,
              let (newCrop, _) = resizedCrop(from: lastPanelFrame, to: frame) else { return }
        crop = newCrop
        if movedOrigin != nil { movedOrigin = frame.origin }
        lastPanelFrame = frame
        syncFrameWithTarget()
    }

    /// The crop a resize from `old` to `new` asks for, and the panel frame
    /// that shows it. The crop moves the same edges by the same amount; it
    /// cannot grow past the window, so anything outside is trimmed, and the
    /// panel loses the same amount from the same edges.
    private func resizedCrop(from old: NSRect, to new: NSRect) -> (CGRect, NSRect)? {
        guard let crop, old != .zero, old != new,
              let target = Self.getWindowFrame(windowID: targetWindowID) else { return nil }
        // Screen points run up, window points run down: the top edge moving
        // up by d moves the crop's top up the window by d.
        let proposed = CGRect(x: crop.minX + (new.minX - old.minX),
                              y: crop.minY + (old.maxY - new.maxY),
                              width: new.width, height: new.height)
        var trimmed = proposed.intersection(CGRect(origin: .zero, size: target.size))
        if trimmed.isNull { trimmed = crop }
        trimmed = trimmed.integral
        let panel = NSRect(x: new.minX + (trimmed.minX - proposed.minX),
                           y: new.minY + (proposed.maxY - trimmed.maxY),
                           width: trimmed.width, height: trimmed.height)
        return (trimmed, panel)
    }

    /// AppKit resizes through here. A resize that would take a cropped pin
    /// past the edge of the window is trimmed before it is applied, so the
    /// edge stops at the window instead of overshooting and snapping back.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if isCropped, !applyingFrame, inLiveResize,
           let (_, panel) = resizedCrop(from: lastPanelFrame, to: frameRect) {
            super.setFrame(panel, display: flag)
            return
        }
        super.setFrame(frameRect, display: flag)
    }

    /// Until the stream sends a frame of the new area, show the matching part
    /// of the frame already on the layer. The stream sends frames only when the
    /// window changes, so without this a quiet window would show its old,
    /// whole picture squeezed into the new panel. Clearing a crop has nothing
    /// to show beyond the old area, so the pin is left empty for that moment
    /// rather than stretched.
    private func showLastFrame(from old: CGRect, to new: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard old.width > 0, old.height > 0, old.contains(new) else {
            contentLayer.contents = nil
            displayedFrame = nil
            contentLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        // Unit rectangle of `new` within `old`, bottom-left origin, composed
        // with any part-frame already being shown.
        let current = contentLayer.contentsRect
        let ux = (new.minX - old.minX) / old.width
        let uy = (old.maxY - new.maxY) / old.height
        let uw = new.width / old.width, uh = new.height / old.height
        contentLayer.contentsRect = CGRect(x: current.minX + ux * current.width,
                                           y: current.minY + uy * current.height,
                                           width: uw * current.width, height: uh * current.height)
    }

    /// Whether the user is working in the pinned window itself: its app is
    /// frontmost and it is that app's front window.
    ///
    /// A whole-window pin drops behind whenever its app is active, which is
    /// right for it: it covers the window exactly. A cropped pin is small and
    /// often moved elsewhere, typically from a window torn off for the
    /// purpose, so it must stay up while another window of the same app is in
    /// use, such as a different Safari window.
    ///
    /// The app is asked for its main window through Accessibility. The window
    /// list cannot answer this: on macOS 27 the badge the system draws on a
    /// window being captured is a small normal-layer window owned by the
    /// captured app, in front of it, so the app's front window in the list is
    /// never the pinned one (measured 2026-10-11, TextEdit).
    ///
    /// The main window is identified by its window number, not by matching
    /// frames as `WindowLevelManager.axWindow` does: every tab in a tab group
    /// is its own window with the same frame, so a frame match cannot tell the
    /// selected tab from the one pinned.
    var isTargetInUse: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return false }
        let app = AXUIElementCreateApplication(targetPID)
        var mainRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &mainRef) == .success,
              let main = mainRef, CFGetTypeID(main) == AXUIElementGetTypeID() else { return false }
        var mainID: CGWindowID = 0
        guard _AXUIElementGetWindow(main as! AXUIElement, &mainID) == .success else { return false }
        return mainID == targetWindowID
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
        AXScroller.forget(windowID: targetWindowID)
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
        lastStreamGeometry = currentStreamGeometry()
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
        // A crop films only that part of the window. For a single-window
        // filter the rectangle is in points from the window's top-left corner.
        if let windowSize = Self.windowBounds(targetWindowID)?.size,
           let crop = clampedCrop(windowSize: windowSize) {
            config.sourceRect = crop
        }
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
        let wanted = panelFrame(forTarget: target)
        if frame != wanted {
            applyingFrame = true
            setFrame(wanted, display: false)
            applyingFrame = false
        }
        lastPanelFrame = frame
        // Window resized or crop changed → the stream's output size and the
        // area it films need to follow.
        let geometry = streamGeometry(windowSize: target.size, panelSize: wanted.size)
        if stream != nil, !geometry.equalTo(lastStreamGeometry) {
            lastStreamGeometry = geometry
            applyCaptureRate()
        }
    }

    /// Where the panel goes: over the whole window, over the cropped area of
    /// it, or wherever the user dragged a cropped pin to.
    private func panelFrame(forTarget target: NSRect) -> NSRect {
        guard let crop = clampedCrop(windowSize: target.size) else { return target }
        if let movedOrigin { return NSRect(origin: movedOrigin, size: crop.size) }
        // Window points run down from the top; screen points run up.
        return NSRect(x: target.minX + crop.minX, y: target.maxY - crop.maxY,
                      width: crop.width, height: crop.height)
    }

    /// What the stream must be configured for: the filmed area's origin and
    /// the panel's size, which is the stream's output size in points.
    private func streamGeometry(windowSize: CGSize, panelSize: CGSize) -> CGRect {
        CGRect(origin: shownRect(windowSize: windowSize).origin, size: panelSize)
    }

    private func currentStreamGeometry() -> CGRect {
        let windowSize = Self.windowBounds(targetWindowID)?.size ?? frame.size
        return streamGeometry(windowSize: windowSize, panelSize: frame.size)
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
                // Stage B measurement, behind its own flag. See AXScroller.
                AXScroller.probe(pid: self.targetPID, windowID: self.targetWindowID)
            }
            let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
            if self.contentLayer.contentsRect != unit {
                // Showing part of an old frame after a crop change. Only a
                // frame sized for the new panel is of the new area; frames of
                // the old area can still be in flight and must not be shown
                // whole in the new panel.
                let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
                let wantW = Int(self.frame.width * self.streamPixelScale)
                let wantH = Int(self.frame.height * self.streamPixelScale)
                guard abs(w - wantW) <= 2, abs(h - wantH) <= 2 else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.contentLayer.contentsRect = unit
                self.displayedFrame = pixelBuffer
                self.contentLayer.contents = surfaceRef
                CATransaction.commit()
                return
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
