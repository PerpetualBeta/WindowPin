import AppKit
import ApplicationServices
import Foundation

// MARK: - Logging

private let logFile: FileHandle? = {
    let path = "/tmp/windowpin.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func wplog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    logFile?.seekToEndOfFile()
    logFile?.write(line.data(using: .utf8)!)
}

// MARK: - Window Level Manager (Accessibility API approach)

enum WindowLevelManager {

    /// Raise a window to the front of ALL windows (cross-app) without activating its app's keyboard focus.
    /// Uses AXUIElement kAXRaiseAction + NSRunningApplication ordering.
    static func raiseWindow(pid: pid_t, windowID: UInt32) {
        let app = AXUIElementCreateApplication(pid)

        // Check if we're trusted for accessibility
        let trusted = AXIsProcessTrusted()

        // Get all windows for this app
        var windowsRef: AnyObject?
        let axErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard axErr == .success, let windows = windowsRef as? [AXUIElement] else {
            wplog("raiseWindow: could not get windows for pid=\(pid) axErr=\(axErr.rawValue) trusted=\(trusted)")
            return
        }

        // Find the specific window by matching against CGWindowList
        // We need to match AX windows to CGWindowIDs
        for axWindow in windows {
            // Try to raise each window — the right one will match
            // First, check if this AX window corresponds to our target windowID
            // by comparing position/size with CGWindowList data
            if matchesWindowID(axWindow: axWindow, pid: pid, targetWID: windowID) {
                let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                wplog("raiseWindow: AXRaise wid=\(windowID) pid=\(pid) result=\(raiseResult.rawValue)")

                // Activate the app so the raised window also takes keyboard
                // focus — this is an explicit "switch to the real window" action.
                if let runningApp = NSRunningApplication(processIdentifier: pid) {
                    runningApp.activate()
                    wplog("raiseWindow: activated app '\(runningApp.localizedName ?? "?")'")
                }
                return
            }
        }

        // Fallback: raise the first window and hope for the best
        if let firstWindow = windows.first {
            let raiseResult = AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
            wplog("raiseWindow: fallback AXRaise pid=\(pid) result=\(raiseResult.rawValue)")

            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                runningApp.activate()
            }
        }
    }

    /// Match an AXUIElement window to a CGWindowID by comparing position and size.
    private static func matchesWindowID(axWindow: AXUIElement, pid: pid_t, targetWID: UInt32) -> Bool {
        // Get AX position and size
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return false
        }

        var axPos = CGPoint.zero
        var axSize = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &axPos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &axSize)

        // Find matching CGWindow entry
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for entry in windowList {
            guard let wid = entry[kCGWindowNumber as String] as? UInt32,
                  wid == targetWID,
                  let entryPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  entryPID == pid,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let cgX = boundsDict["X"] ?? 0
            let cgY = boundsDict["Y"] ?? 0
            let cgW = boundsDict["Width"] ?? 0
            let cgH = boundsDict["Height"] ?? 0

            if abs(axPos.x - cgX) < 5 && abs(axPos.y - cgY) < 5 &&
               abs(axSize.width - cgW) < 5 && abs(axSize.height - cgH) < 5 {
                return true
            }
        }
        return false
    }

    /// Pin: raise the window immediately.
    static func pin(windowID: UInt32, pid: pid_t) -> Bool {
        wplog("pin(wid=\(windowID), pid=\(pid)): raising via AX")
        raiseWindow(pid: pid, windowID: windowID)
        return true
    }

    /// Re-raise a pinned window (called periodically / on app activation).
    static func reraise(windowID: UInt32, pid: pid_t) {
        raiseWindow(pid: pid, windowID: windowID)
    }

    /// Unpin is just tracking — no level to reset.
    static func unpin(windowID: UInt32) -> Bool {
        wplog("unpin(wid=\(windowID))")
        return true
    }
}
