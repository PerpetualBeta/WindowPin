import SwiftUI
import ScreenCaptureKit

struct WindowPinSettingsContent: View {
    let tracker: PinnedWindowTracker
    let delegate: AppDelegate

    // @AppStorage (not computed Bindings) so SwiftUI's selection state stays in
    // sync with the store — a computed Binding here goes stale after the first
    // change and silently swallows every second interaction.
    @AppStorage("captureRate") private var captureRate: Double = 30.0
    @AppStorage("forwardEvents") private var forwardEvents: Bool = true
    @AppStorage("pinToAllSpaces") private var pinToAllSpaces: Bool = false

    var body: some View {
        Section("Overlays") {
            Picker("Maximum frame rate", selection: $captureRate) {
                Text("0.5 fps").tag(0.5)
                Text("1 fps").tag(1.0)
                Text("2 fps").tag(2.0)
                Text("5 fps").tag(5.0)
                Text("10 fps").tag(10.0)
                Text("15 fps").tag(15.0)
                Text("30 fps").tag(30.0)
                Text("60 fps").tag(60.0)
            }
            .onChange(of: captureRate) { _, _ in
                tracker.updateCaptureRate()
            }
            Text("Overlays only update when the window's content changes, so high rates cost nothing for static content.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Interact through overlays", isOn: $forwardEvents)
            Text("Clicks and scrolls on an overlay are sent to the pinned window. ⌘-click an overlay to switch to the real window. When off, any click switches to the real window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Pin to all spaces", isOn: $pinToAllSpaces)
                .onChange(of: pinToAllSpaces) { _, _ in
                    tracker.updateAllSpaces()
                }
        }

        Section("Shortcut") {
            JorvikShortcutRecorder(
                label: "Pin/Unpin window",
                keyCode: Binding(
                    get: { delegate.shortcutKeyCode },
                    set: { delegate.shortcutKeyCode = $0 }
                ),
                modifiers: Binding(
                    get: { delegate.shortcutModifiers },
                    set: { delegate.shortcutModifiers = $0 }
                ),
                displayString: { delegate.shortcutDisplayString() },
                onChanged: { delegate.saveShortcutAndUpdateTap() },
                eventTapToDisable: delegate.currentEventTap
            )
        }

        Section("Permissions") {
            HStack {
                Text("Accessibility")
                Spacer()
                if AXIsProcessTrusted() {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Grant Access") {
                        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
                        AXIsProcessTrustedWithOptions(opts)
                    }
                    .font(.caption)
                }
            }

            HStack {
                Text("Screen Recording")
                Spacer()
                if CGPreflightScreenCaptureAccess() {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Grant Access") {
                        CGRequestScreenCaptureAccess()
                    }
                    .font(.caption)
                }
            }
        }

        MenuBarVisibilitySettings()

        MenuBarPillSettings { delegate.updateIcon() }
    }
}
