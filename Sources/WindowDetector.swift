import AppKit
import ApplicationServices

struct ForeignWindow: Hashable {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: ForeignWindow, rhs: ForeignWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

enum WindowDetector {

    /// Returns the frontmost window that does NOT belong to this process.
    static func getFrontmostForeignWindow() -> ForeignWindow? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard frontApp.processIdentifier != myPID else { return nil }

        // Step 1: Get focused window title via Accessibility API
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        var axWindowRef: AnyObject?
        let axResult = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &axWindowRef)

        var axTitle: String?
        var axBounds: CGRect?

        if axResult == .success, let axWindow = axWindowRef {
            // Get title
            var titleRef: AnyObject?
            if AXUIElementCopyAttributeValue(axWindow as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success {
                axTitle = titleRef as? String
            }
            // Get position + size for fallback matching
            var posRef: AnyObject?
            var sizeRef: AnyObject?
            if AXUIElementCopyAttributeValue(axWindow as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(axWindow as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success {
                var pos = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                axBounds = CGRect(origin: pos, size: size)
            }
        }

        // Step 2: Enumerate on-screen windows and match by PID + title (or bounds)
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let targetPID = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? "Unknown"

        // Try exact PID + title match first
        if let title = axTitle, !title.isEmpty {
            for entry in windowList {
                guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                      pid == targetPID,
                      let wid = entry[kCGWindowNumber as String] as? UInt32,
                      let layer = entry[kCGWindowLayer as String] as? Int,
                      layer == 0 else { continue }

                let name = entry[kCGWindowName as String] as? String ?? ""
                if name == title {
                    return ForeignWindow(windowID: wid, ownerPID: pid, ownerName: appName, windowTitle: name)
                }
            }
        }

        // Fallback: match by PID + bounds
        if let bounds = axBounds {
            for entry in windowList {
                guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                      pid == targetPID,
                      let wid = entry[kCGWindowNumber as String] as? UInt32,
                      let layer = entry[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

                let entryBounds = CGRect(
                    x: boundsDict["X"] ?? 0,
                    y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0,
                    height: boundsDict["Height"] ?? 0
                )
                if abs(entryBounds.origin.x - bounds.origin.x) < 2 &&
                   abs(entryBounds.origin.y - bounds.origin.y) < 2 &&
                   abs(entryBounds.width - bounds.width) < 2 &&
                   abs(entryBounds.height - bounds.height) < 2 {
                    let name = entry[kCGWindowName as String] as? String ?? ""
                    return ForeignWindow(windowID: wid, ownerPID: pid, ownerName: appName, windowTitle: name)
                }
            }
        }

        // Last resort: first layer-0 window for this PID
        for entry in windowList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid == targetPID,
                  let wid = entry[kCGWindowNumber as String] as? UInt32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }

            let name = entry[kCGWindowName as String] as? String ?? ""
            return ForeignWindow(windowID: wid, ownerPID: pid, ownerName: appName, windowTitle: name)
        }

        return nil
    }

    /// Returns the set of all on-screen window IDs (layer 0).
    static func allOnScreenWindowIDs() -> Set<UInt32> {
        guard let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<UInt32>()
        for entry in windowList {
            if let wid = entry[kCGWindowNumber as String] as? UInt32,
               let layer = entry[kCGWindowLayer as String] as? Int,
               layer >= 0 {
                ids.insert(wid)
            }
        }
        return ids
    }
}
