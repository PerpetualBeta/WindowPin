import Foundation
import AppKit

/// One global hotkey published by a Jorvik app at runtime so other Jorvik
/// utilities (notably ShortcutHUD) can surface what bindings are live.
///
/// Each app declares the bindings it has actually registered (defaults +
/// any user customisations) plus the context where each fires. The list
/// is written to the publishing app's UserDefaults under
/// `JorvikHotkeyRegistry.userDefaultsKey` as a JSON-encoded array;
/// readers pull it via `CFPreferencesCopyAppValue` against the bundle ID.
struct JorvikHotkey: Codable, Hashable {
    let actionTitle: String
    let keyCode: UInt16
    let modifiers: UInt        // NSEvent.ModifierFlags raw
    let activeContext: ActiveContext

    enum ActiveContext: String, Codable {
        case anywhere       // fires regardless of frontmost app
        case browser        // only fires when frontmost is a web browser
    }

    init(actionTitle: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, activeContext: ActiveContext) {
        self.actionTitle = actionTitle
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
        self.activeContext = activeContext
    }
}

enum JorvikHotkeyRegistry {
    static let userDefaultsKey = "JorvikRegisteredHotkeys"

    /// Publish the calling app's full set of registered hotkeys. Idempotent —
    /// safe to call on every launch and whenever a binding changes.
    static func publish(_ hotkeys: [JorvikHotkey]) {
        guard let data = try? JSONEncoder().encode(hotkeys) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    /// Read another app's registry by bundle ID. Returns an empty array if
    /// the app hasn't published, can't be read, or the data is malformed.
    static func read(from bundleID: String) -> [JorvikHotkey] {
        guard let raw = CFPreferencesCopyAppValue(userDefaultsKey as CFString, bundleID as CFString) as? Data,
              let hotkeys = try? JSONDecoder().decode([JorvikHotkey].self, from: raw)
        else { return [] }
        return hotkeys
    }
}
