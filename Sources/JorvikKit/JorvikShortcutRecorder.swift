import AppKit
import SwiftUI

/// An inline keyboard shortcut recorder for use in settings forms.
/// Displays the current shortcut, and when "Change..." is clicked,
/// switches to recording mode and captures the next key combo directly.
struct JorvikShortcutRecorder: View {
    let label: String
    @Binding var keyCode: UInt16
    @Binding var modifiers: NSEvent.ModifierFlags
    var displayString: () -> String
    var onChanged: (() -> Void)?

    /// Supplied when the shortcut may be unset. Storage differs across the
    /// estate — some apps keep a `keyCode`/`modifiers` pair, others a
    /// `HotkeyConfig` in `HotkeyStore` — so the call site decides what clearing
    /// means and this view only offers the button and refreshes afterwards.
    ///
    /// Left nil no Clear button is drawn, which is what the apps that never had
    /// one expect. It exists because the recorder this replaced,
    /// `HotkeyRecorderView`, had a clear affordance and dropping it would have
    /// been a regression for the four apps moving across.
    var onClear: (() -> Void)?
    var eventTapToDisable: CFMachPort?

    /// Whether a shortcut is actually stored, asked of the bindings rather than
    /// inferred from `shortcutText`.
    ///
    /// The Clear button used to appear whenever the display string was
    /// non-empty, which works only for a call site that returns "" when nothing
    /// is set. An app that shows a placeholder instead, "Not set" for example,
    /// got a Clear button permanently, including with nothing to clear. Reading
    /// a localised label to decide a state is the fault; this reads the state.
    ///
    /// `keyCode == 0` is `a`, so it cannot mean "unset" on its own. It does not
    /// have to: recording requires command, control or option, so a stored
    /// shortcut always carries a modifier. This is the same test
    /// `JorvikHotkeyManager.register` uses to decide whether a slot is worth
    /// registering.
    private var isSet: Bool { keyCode != 0 || !modifiers.isEmpty }

    /// Set when a keypress was rejected for carrying no modifier, so the prompt
    /// can say why instead of appearing to ignore the user.
    @State private var needsModifier = false

    /// Called with `true` when recording begins and `false` when it ends.
    ///
    /// A global hotkey registered through Carbon's `RegisterEventHotKey` is
    /// consumed by the system before the keystroke reaches this view. Pressing
    /// the shortcut that is already set therefore fires the app's action instead
    /// of being recorded, and the existing shortcut can never be re-recorded —
    /// which is exactly what it looks like from the user's side: "I clicked
    /// Change, pressed my shortcut, and the app just did the thing."
    ///
    /// The owner must unregister its hotkeys for the duration. Apps driving a
    /// shortcut from a CGEvent tap use `eventTapToDisable` instead; a plain
    /// `addGlobalMonitorForEvents` does not consume the event, so those apps
    /// record correctly but should still use this to avoid firing the action.
    var onRecordingChanged: ((Bool) -> Void)?

    /// The shortcut as text, read every time the body is evaluated.
    ///
    /// **This used to be `@State`, set once in `.onAppear`, and that was a
    /// silent bug.** SwiftUI runs a child's `.onAppear` before its parent's,
    /// measured 2026-09-22, so when the call site loads its stored shortcut in
    /// its own `.onAppear` — which `JorvikHotkeyRow` does — this view had
    /// already snapshotted the value from *before* the load. The row then showed
    /// no shortcut at all, for the life of the window, however many were set.
    ///
    /// It read as "nothing is bound here", and it was believed: Rainy Day's
    /// activation shortcut was reported as unset when it was registered and
    /// working the whole time.
    ///
    /// Computing it removes the question of when to refresh. Every path that
    /// used to reassign it — record, clear, cancel, appear — now needs nothing,
    /// because changing the bindings re-evaluates the body.
    private var shortcutText: String { displayString() }
    @State private var isRecording = false
    @State private var localMonitor: Any?
    // There is no global key monitor, deliberately.
    //
    // Recording used to install one alongside the local monitor, to catch
    // keystrokes arriving while this app was not frontmost. That needs an
    // Accessibility grant, and without one the monitor is created and its
    // handler never fires — dead code that cost the consuming app a Grant
    // Access button for the right to read input across every other application
    // on the machine.
    //
    // It was never reachable anyway: recording starts when the user clicks the
    // field, so this app IS frontmost and the local monitor has the keystroke.

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if isRecording {
                Text(needsModifier
                     ? L10n.string("shortcut.needs_modifier",
                                   defaultValue: "Hold \u{2318}, \u{2303} or \u{2325}")
                     : L10n.string("shortcut.press", defaultValue: "Press shortcut\u{2026}"))
                    .foregroundStyle(.orange)
                    .font(.caption)
                Button(L10n.string("shortcut.cancel", defaultValue: "Cancel")) {
                    stopRecording()
                }
                .font(.caption)
            } else {
                Text(shortcutText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                if onClear != nil, isSet {
                    Button(L10n.string("shortcut.clear", defaultValue: "Clear")) {
                        onClear?()
                    }
                    .font(.caption)
                }
                Button(L10n.string("shortcut.change", defaultValue: "Change\u{2026}")) {
                    startRecording()
                }
                .font(.caption)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        // Disable event tap if provided (e.g. WindowPin's CGEvent tap)
        if let tap = eventTapToDisable {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        isRecording = true
        needsModifier = false
        onRecordingChanged?(true)

        let handleEvent = { (event: NSEvent) in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Escape cancels
            if event.keyCode == 53 {
                stopRecording()
                return
            }

            // Require at least one modifier. Silently swallowing the press
            // made the recorder look broken: nothing happened and nothing said
            // why. Now the prompt changes instead.
            //
            // Glyphs rather than the words "command, control or option",
            // against the estate's usual rule. That rule is about prose, where
            // the symbols are harder to read than the words. This is a key cap
            // being named inside a shortcut control that already draws the
            // shortcut itself in glyphs, and matching what macOS puts in its own
            // menus beats internal consistency here. Jonathan's call, 2026-09-22.
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                needsModifier = true
                return
            }

            let cleanFlags = flags.intersection([.command, .control, .option, .shift])
            keyCode = event.keyCode
            modifiers = cleanFlags
            onChanged?()
            stopRecording()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        isRecording = false
        needsModifier = false

        // Re-enable event tap
        if let tap = eventTapToDisable {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        onRecordingChanged?(false)
    }
}

extension Notification.Name {
    static let jorvikShortcutChanged = Notification.Name("JorvikShortcutChanged")

    /// Posted while a recorder is listening, `userInfo["recording"]` a `Bool`.
    ///
    /// For apps whose settings view has no route back to the delegate and
    /// already decouple re-registration through `jorvikShortcutChanged`. Apps
    /// that can pass a closure should use the recorder's `onRecordingChanged`
    /// instead — this exists so neither has to invent its own mechanism.
    static let jorvikShortcutRecordingChanged = Notification.Name("JorvikShortcutRecordingChanged")
}

enum JorvikShortcutPanel {
    // MARK: - Utility: format a keyCode + modifiers as a display string

    static func displayString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToCharacter(keyCode))
        return parts.joined()
    }

    private static func keyCodeToCharacter(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return map[keyCode] ?? "?\(keyCode)"
    }
}
