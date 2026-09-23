import AppKit
import ApplicationServices
import Foundation

// MARK: - Logging

// Diagnostic logging — off by default, enabled per-machine via:
//   defaults write cc.jorviksoftware.WindowPin debugLogging -bool YES
//   defaults delete cc.jorviksoftware.WindowPin debugLogging   # turn off
// When on, timestamped lines are appended to
//   ~/Library/Logs/WindowPin/windowpin.log
//
// Never write to Console/stderr or /tmp. This mirrors the Jorvik logging
// convention (Ballast/Sources/Log.swift): a symlink-safe append to a 0700
// directory, gated behind a UserDefaults flag read on every call.
//
// What this replaced: an ungated FileHandle on /tmp/windowpin.log, opened with
// `createFile`, which TRUNCATED the log on every launch and wrote for every
// user whether they wanted it or not. /tmp is shared and world-readable, and
// this log records PINNED WINDOW TITLES.
private let wpLogPath: String = {
    let logs = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("WindowPin", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return logs.appendingPathComponent("windowpin.log").path
}()
private let wpLogQueue = DispatchQueue(label: "cc.jorviksoftware.WindowPin.log")
private let wpLogFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// The message is an `@autoclosure` so a disabled call builds no string. Most
/// sites here fire on a state change, but the event forwarder logs per scroll
/// event, which arrives continuously while the user is scrolling.
func wplog(_ msg: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
    let line = "\(wpLogFmt.string(from: Date()))  \(msg())\n"
    wpLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        // O_NOFOLLOW + 0700 parent dir closes the symlink-attack vector.
        let fd = open(wpLogPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }
}

// MARK: - Window Level Manager (Accessibility API approach)

enum WindowLevelManager {

    /// Raise a window to the front of ALL windows (cross-app) without activating its app's keyboard focus.
    /// Uses AXUIElement kAXRaiseAction + NSRunningApplication ordering.
    /// - Parameter activate: also give the app keyboard focus. Deliberately has
    ///   NO default. Raising and activating were welded together here, and every
    ///   caller therefore activated whether it meant to or not; requiring the
    ///   argument stops a future call site doing that by omission.
    static func raiseWindow(pid: pid_t, windowID: UInt32, activate: Bool) {
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
                if activate, let runningApp = NSRunningApplication(processIdentifier: pid) {
                    runningApp.activate()
                    wplog("raiseWindow: activated app '\(runningApp.localizedName ?? "?")'")
                }
                return
            }
        }

        // No fallback. This used to raise `windows.first` "and hope for the
        // best", which on a match miss raises an unrelated window of that app
        // and — because activation was welded in — brings the whole app
        // forward. Doing nothing and saying so is better than acting on the
        // wrong window.
        wplog("raiseWindow: no AX window matched wid=\(windowID) pid=\(pid); doing nothing")
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



    /// Unpin is just tracking — no level to reset.
    static func unpin(windowID: UInt32) -> Bool {
        wplog("unpin(wid=\(windowID))")
        return true
    }
}
