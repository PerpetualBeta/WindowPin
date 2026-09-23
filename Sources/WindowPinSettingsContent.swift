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

    /// Both kept current by JorvikKit — see `JorvikPermissionWatcher`. These two rows used
    /// to be read inline in `body`, so nothing ever caused them to re-render and granting
    /// either permission left the row still asking for it.
    @StateObject private var accessibility = JorvikPermissionWatcher.accessibility()
    @StateObject private var screenRecording = JorvikPermissionWatcher.screenRecording()

    var body: some View {
        Section("Overlays") {
            VStack(alignment: .leading, spacing: 4) {
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
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Interact through overlays", isOn: $forwardEvents)
                Text("Clicks and scrolls on an overlay are sent to the pinned window. \u{2318}-click an overlay to switch to the real window. When off, any click switches to the real window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                onClear: {
                    // Pinning stays available from the menu, which falls back
                    // to the last foreign window, so clearing costs nothing but
                    // the shortcut itself.
                    delegate.shortcutKeyCode = 0
                    delegate.shortcutModifiers = []
                    delegate.saveShortcutAndUpdateTap()
                },
                eventTapToDisable: delegate.currentEventTap
            )
        }

        Section("Permissions") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if accessibility.isGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Grant Access") {
                            JorvikPermissionWatcher.promptForAccessibility()
                        }
                        .font(.caption)
                    }
                }
                // Wording taken from the README, so the claim matches what the
                // app actually needs rather than being invented here.
                Text("Required. Needed for the global keyboard shortcut, for forwarding clicks and scrolls to pinned windows, and for bringing windows to the front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Screen Recording")
                    Spacer()
                    if screenRecording.isGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Grant Access") {
                            // The prompt only ever appears once; after a denial this silently
                            // records a request and returns false, so send them where they can
                            // actually flip it.
                            if !CGRequestScreenCaptureAccess() {
                                JorvikPermissionWatcher.openSettings(pane: .screenRecording)
                            }
                        }
                        .font(.caption)
                    }
                }
                Text("Required. Needed to capture window content for the live overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        MenuBarVisibilitySettings()

        MenuBarPillSettings { delegate.updateIcon() }
    }
}
