import AppKit
import ApplicationServices

/// Can a pinned window be scrolled through the Accessibility tree, while its
/// app is in the background and its window is covered by the overlay?
///
/// This is a MEASUREMENT, not a feature. Everything else has been ruled out:
/// a posted CGEvent arrives at the target and binds to the right window but is
/// always placed at the window's top-left corner, so AppKit drops it; and a
/// window cannot be ordered above another app's windows without activating its
/// app, which is the thing we are trying to avoid. What neither of those ruled
/// out is driving the target directly — not by re-creating the user's input,
/// but by setting the scroll position of whatever `AXScrollArea` is under the
/// pointer.
///
///     defaults write cc.jorviksoftware.WindowPin axScrollProbe -bool YES
///
/// It reports what it finds and then makes ONE attempt to move the scroll
/// position, so the answer is visible on screen as well as in the log.
enum AXScroller {

    /// Attribute reads are capped. A beachballed target must not take
    /// WindowPin's main thread with it, which is why every call here runs on a
    /// background queue with a short messaging timeout.
    private static let messagingTimeout: Float = 0.25
    private static let queue = DispatchQueue(label: "cc.jorviksoftware.WindowPin.axprobe")

    static func probe(pid: pid_t, windowID: CGWindowID) {
        guard UserDefaults.standard.bool(forKey: "axScrollProbe") else { return }
        queue.async { run(pid: pid, windowID: windowID) }
    }

    private static func run(pid: pid_t, windowID: CGWindowID) {
        let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        wplog("axprobe: START pid=\(pid) wid=\(windowID) frontmost=\(frontBefore)")

        guard let window = WindowLevelManager.axWindow(pid: pid, windowID: UInt32(windowID)) else {
            wplog("axprobe: could not find the AX window — cannot proceed")
            return
        }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)

        var areas: [AXUIElement] = []
        collectScrollAreas(under: window, depth: 0, into: &areas)
        wplog("axprobe: found \(areas.count) AXScrollArea(s)")
        guard let area = areas.first else {
            wplog("axprobe: RESULT — no scroll area in this window. Nothing to drive.")
            return
        }

        // The scroll bar is the thing with a settable value; the area itself
        // usually is not.
        guard let bar = copyElement(area, kAXVerticalScrollBarAttribute) else {
            wplog("axprobe: RESULT — scroll area has no vertical scroll bar.")
            return
        }

        var settable: DarwinBoolean = false
        let settableErr = AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable)
        let before = copyDouble(bar, kAXValueAttribute)
        let minV = copyDouble(bar, kAXMinValueAttribute)
        let maxV = copyDouble(bar, kAXMaxValueAttribute)
        wplog("axprobe: scrollbar value=\(fmt(before)) min=\(fmt(minV)) max=\(fmt(maxV)) "
              + "settable=\(settable.boolValue) (err=\(settableErr.rawValue))")

        guard settable.boolValue, let current = before else {
            wplog("axprobe: RESULT — the scroll position is NOT settable. This route is closed.")
            return
        }

        // Move by a tenth of the range, away from whichever end we are at, so
        // the movement is visible whatever the starting position.
        let lo = minV ?? 0, hi = maxV ?? 1
        let span = hi - lo
        guard span > 0 else {
            wplog("axprobe: RESULT — zero scroll range, nothing to move.")
            return
        }
        let target = current + (current < hi - span * 0.15 ? span * 0.1 : -span * 0.1)
        // A scroll bar's value is a plain number, not an AXValue struct.
        let setErr = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                                  target as CFNumber)
        wplog("axprobe: set value \(fmt(current)) -> \(fmt(target)) result=\(setErr.rawValue)")

        // Read back and see what the app actually did with it.
        usleep(200_000)
        let after = copyDouble(bar, kAXValueAttribute)
        let frontAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let moved = (after ?? current) != current
        wplog("axprobe: value after=\(fmt(after)) moved=\(moved) frontmost=\(frontAfter) "
              + "(was \(frontBefore))")
        if moved && frontAfter == frontBefore {
            wplog("axprobe: RESULT — SCROLLED, and focus did not move. This route WORKS.")
        } else if moved {
            wplog("axprobe: RESULT — scrolled, but the frontmost app CHANGED. Focus was stolen.")
        } else {
            wplog("axprobe: RESULT — the set was accepted but nothing moved. This route is closed.")
        }
    }

    // MARK: - Tree walking

    /// Depth-limited on purpose. A deep tree on a busy app is exactly where the
    /// 29-second Accessibility walks came from elsewhere in the estate.
    private static func collectScrollAreas(under element: AXUIElement, depth: Int,
                                           into areas: inout [AXUIElement]) {
        guard depth < 12, areas.count < 8 else { return }
        if let role = copyString(element, kAXRoleAttribute), role == kAXScrollAreaRole {
            areas.append(element)
        }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            collectScrollAreas(under: child, depth: depth + 1, into: &areas)
        }
    }

    private static func copyElement(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return nil }
        guard let v = ref, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func copyString(_ e: AXUIElement, _ attr: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func copyDouble(_ e: AXUIElement, _ attr: String) -> Double? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.doubleValue
    }

    private static func fmt(_ d: Double?) -> String {
        guard let d else { return "nil" }
        return String(format: "%.4f", d)
    }
}
