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

    // MARK: - Driving a pinned window

    /// How much of the scroll range one point of scrolling moves.
    ///
    /// A scroll bar's value is a fraction of the whole document and carries no
    /// information about how long the document is, so there is no way to derive
    /// a pixel-accurate mapping from it. This is therefore a feel setting, and
    /// it is a knob rather than a constant because the right value depends on
    /// the document: the same gesture should not fling you through a 40-item
    /// Finder window and crawl through a long web page.
    ///
    ///     defaults write cc.jorviksoftware.WindowPin axScrollSensitivity -float 0.002
    private static var sensitivity: Double {
        let stored = UserDefaults.standard.double(forKey: "axScrollSensitivity")
        return stored > 0 ? stored : 0.0015
    }

    /// The resolved scroll bar for a window, with the walk cached.
    ///
    /// Walking the tree costs 110-150 ms here, measured by the Stage B probe.
    /// Doing that per scroll event would be unusable, so the result is cached
    /// per window and re-resolved only when it goes stale or stops answering.
    /// Keyed by window, NOT by gesture: a wheel mouse reports no gesture phase
    /// at all, so there is nothing to key on.
    /// Every settable scroll bar in the window, with the frame of the area it
    /// belongs to, so the one under the pointer can be chosen per event.
    ///
    /// Choosing the FIRST settable bar is wrong and was immediately visible: a
    /// Finder window has two scroll areas and the sidebar comes first in the
    /// tree, so every scroll moved the Quick Links list no matter where the
    /// pointer was. Only the walk is cached; picking by pointer is a rectangle
    /// test and costs nothing.
    private struct Area { let frame: CGRect; let bar: AXUIElement }
    private struct Resolved { let areas: [Area]; let at: Date }
    private static var cache: [CGWindowID: Resolved] = [:]
    private static var lastLoggedShape: [CGWindowID: String] = [:]
    private static let cacheTTL: TimeInterval = 5

    /// Scroll a pinned window by a wheel delta, without touching focus.
    /// - Parameter at: the pointer, in global top-left coordinates, matching the
    ///   space Accessibility reports element frames in.
    static func scroll(pid: pid_t, windowID: CGWindowID, deltaY: CGFloat, at point: CGPoint) {
        guard deltaY != 0 else { return }
        queue.async {
            guard let bar = barUnder(point, pid: pid, windowID: windowID) else { return }
            guard let current = copyDouble(bar, kAXValueAttribute) else {
                cache[windowID] = nil
                return
            }
            // Scrolling content down means moving the scroll position up.
            let target = min(1.0, max(0.0, current - Double(deltaY) * sensitivity))
            guard abs(target - current) > 0.000_01 else { return }
            let err = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                                  target as CFNumber)
            if err != .success {
                wplog("axscroll: set failed err=\(err.rawValue), dropping the cached bar")
                cache[windowID] = nil
            }
        }
    }

    /// The scroll bar for the area under `point`, preferring the SMALLEST area
    /// that contains it. Scroll areas nest, and the innermost one is the one the
    /// user is pointing at; the outermost is usually the whole window.
    private static func barUnder(_ point: CGPoint, pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        guard let areas = resolveAreas(pid: pid, windowID: windowID), !areas.isEmpty else { return nil }
        let hits = areas.filter { $0.frame.contains(point) }
        if let best = hits.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return best.bar
        }
        // Pointer outside every scroll area — the toolbar, say. Do nothing
        // rather than scroll something the user is not pointing at.
        return nil
    }

    private static func resolveAreas(pid: pid_t, windowID: CGWindowID) -> [Area]? {
        if let hit = cache[windowID], Date().timeIntervalSince(hit.at) < cacheTTL {
            return hit.areas
        }
        guard let window = WindowLevelManager.axWindow(pid: pid, windowID: UInt32(windowID)) else {
            wplog("axscroll: no AX window for wid=\(windowID)")
            return nil
        }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        var areas: [AXUIElement] = []
        collectScrollAreas(under: window, depth: 0, into: &areas)
        // The first settable scroll bar wins. Some windows have several areas —
        // a sidebar and a content list — and the sidebar is often first in the
        // tree but not what the user means.
        var resolved: [Area] = []
        for area in areas {
            guard let bar = copyElement(area, kAXVerticalScrollBarAttribute) else { continue }
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable)
            guard settable.boolValue, let frame = frameOf(area) else { continue }
            resolved.append(Area(frame: frame, bar: bar))
        }
        guard !resolved.isEmpty else {
            wplog("axscroll: no settable scroll bar in wid=\(windowID); scrolling unavailable here")
            return nil
        }
        cache[windowID] = Resolved(areas: resolved, at: Date())
        // Only when the answer changes. The cache ages out every few seconds, so
        // logging each re-resolve turns a steady scroll into a wall of identical
        // lines.
        let shape = resolved.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ",")
        defer { lastLoggedShape[windowID] = shape }
        guard lastLoggedShape[windowID] != shape else { return resolved }
        wplog("axscroll: resolved \(resolved.count) scrollable area(s) for wid=\(windowID): "
              + resolved.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
                        .joined(separator: " "))
        return resolved
    }

    /// An element's frame in global top-left coordinates, which is the space
    /// Accessibility reports and the same one `CGWindowListCopyWindowInfo` uses.
    private static func frameOf(_ e: AXUIElement) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Forget a window's cached element when it is unpinned.
    static func forget(windowID: CGWindowID) { queue.async { cache[windowID] = nil } }

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
