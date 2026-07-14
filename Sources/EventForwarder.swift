import AppKit
import ApplicationServices

/// Synthesises CGEvents from mouse/scroll events received by an overlay and
/// posts them directly to the pinned window's process, so the user can
/// interact with the real window "through" its overlay without switching apps.
///
/// Keyboard events are deliberately NOT forwarded — keyboard focus stays with
/// the app the user is working in, which is the whole point of pinning.
enum EventForwarder {

    /// Forward a mouse or scroll event from the overlay to the target window.
    static func forward(_ event: NSEvent, from overlay: WindowOverlay) {
        guard let targetPoint = mapToTarget(event: event, overlay: overlay) else { return }

        switch event.type {
        case .scrollWheel:
            postScroll(event, at: targetPoint, windowID: overlay.targetWindowID, pid: overlay.targetPID)
        default:
            postMouse(event, at: targetPoint, windowID: overlay.targetWindowID, pid: overlay.targetPID)
        }
    }

    /// Posting to a pid alone is not enough: AppKit in the receiving process
    /// must bind the event to one of its windows, and the window actually under
    /// the pointer is the overlay — a different process's window. Background
    /// apps drop unbound mouse/scroll events (they have no key window to fall
    /// back on). Stamping the target window into the event record — including
    /// the private fields 51 (target window number) and 58 (routing flag) —
    /// makes delivery work regardless of the target app's activation state.
    private static func addressToWindow(_ cg: CGEvent, windowID: CGWindowID, pid: pid_t) {
        cg.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        if let windowField = CGEventField(rawValue: 51) {
            cg.setIntegerValueField(windowField, value: Int64(windowID))
        }
        if let routeField = CGEventField(rawValue: 58) {
            cg.setIntegerValueField(routeField, value: 1)
        }
    }

    /// Shared session-state source so synthesized events carry normal
    /// modifier/button state bookkeeping.
    private static let eventSource = CGEventSource(stateID: .combinedSessionState)

    // MARK: - Coordinate mapping

    /// Map the event's location on the overlay to the equivalent point inside
    /// the target window, in global CG (top-left origin) coordinates.
    /// Proportional mapping keeps the point correct even if the overlay and
    /// target frames briefly disagree (e.g. mid-resize).
    private static func mapToTarget(event: NSEvent, overlay: WindowOverlay) -> CGPoint? {
        guard let targetBounds = cgBounds(windowID: overlay.targetWindowID) else { return nil }
        let size = overlay.frame.size
        guard size.width > 0, size.height > 0 else { return nil }

        let loc = event.locationInWindow
        let fx = loc.x / size.width
        let fyFromTop = (size.height - loc.y) / size.height
        guard fx >= 0, fx <= 1, fyFromTop >= 0, fyFromTop <= 1 else { return nil }

        return CGPoint(
            x: targetBounds.origin.x + fx * targetBounds.width,
            y: targetBounds.origin.y + fyFromTop * targetBounds.height
        )
    }

    /// Raw window bounds in global CG (top-left origin) coordinates.
    private static func cgBounds(windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(
            x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
            width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
        )
    }

    // MARK: - Mouse events

    private static func postMouse(_ event: NSEvent, at point: CGPoint, windowID: CGWindowID, pid: pid_t) {
        guard let (cgType, button) = mouseType(for: event),
              let cg = CGEvent(
                  mouseEventSource: eventSource, mouseType: cgType,
                  mouseCursorPosition: point, mouseButton: button
              ) else { return }

        cg.flags = cgFlags(event.modifierFlags)
        cg.setIntegerValueField(.mouseEventClickState, value: Int64(max(event.clickCount, 1)))
        cg.setDoubleValueField(.mouseEventPressure, value: Double(event.pressure))
        if cgType == .otherMouseDown || cgType == .otherMouseUp || cgType == .otherMouseDragged {
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(event.buttonNumber))
        }
        addressToWindow(cg, windowID: windowID, pid: pid)
        cg.postToPid(pid)
    }

    private static func mouseType(for event: NSEvent) -> (CGEventType, CGMouseButton)? {
        switch event.type {
        case .leftMouseDown: return (.leftMouseDown, .left)
        case .leftMouseUp: return (.leftMouseUp, .left)
        case .leftMouseDragged: return (.leftMouseDragged, .left)
        case .rightMouseDown: return (.rightMouseDown, .right)
        case .rightMouseUp: return (.rightMouseUp, .right)
        case .rightMouseDragged: return (.rightMouseDragged, .right)
        case .otherMouseDown: return (.otherMouseDown, .center)
        case .otherMouseUp: return (.otherMouseUp, .center)
        case .otherMouseDragged: return (.otherMouseDragged, .center)
        default: return nil
        }
    }

    // MARK: - Scroll events

    private static func postScroll(_ event: NSEvent, at point: CGPoint, windowID: CGWindowID, pid: pid_t) {
        let dy = event.scrollingDeltaY
        let dx = event.scrollingDeltaX
        // Trackpads/Magic Mouse report precise pixel deltas; wheel mice report lines.
        let units: CGScrollEventUnit = event.hasPreciseScrollingDeltas ? .pixel : .line
        guard let cg = CGEvent(
            scrollWheelEvent2Source: eventSource, units: units, wheelCount: 2,
            wheel1: scrollSteps(dy), wheel2: scrollSteps(dx), wheel3: 0
        ) else { return }

        if event.hasPreciseScrollingDeltas {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        }
        cg.flags = cgFlags(event.modifierFlags)
        cg.location = point
        addressToWindow(cg, windowID: windowID, pid: pid)
        cg.postToPid(pid)
    }

    /// Round a scroll delta to whole steps without losing sub-step ticks.
    private static func scrollSteps(_ delta: CGFloat) -> Int32 {
        if delta == 0 { return 0 }
        let rounded = Int32(delta.rounded())
        return rounded != 0 ? rounded : (delta > 0 ? 1 : -1)
    }

    // MARK: - Modifiers

    private static func cgFlags(_ ns: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg: CGEventFlags = []
        if ns.contains(.command) { cg.insert(.maskCommand) }
        if ns.contains(.control) { cg.insert(.maskControl) }
        if ns.contains(.option) { cg.insert(.maskAlternate) }
        if ns.contains(.shift) { cg.insert(.maskShift) }
        return cg
    }
}
