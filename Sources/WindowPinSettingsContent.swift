import SwiftUI
import ScreenCaptureKit

struct WindowPinSettingsContent: View {
    let tracker: PinnedWindowTracker
    let delegate: AppDelegate

    var body: some View {
        Section("Capture") {
            Picker("Capture rate", selection: Binding(
                get: { WindowOverlay.captureRate },
                set: { rate in
                    UserDefaults.standard.set(rate, forKey: "captureRate")
                    tracker.updateCaptureRate()
                }
            )) {
                Text("0.5 fps").tag(0.5)
                Text("1 fps").tag(1.0)
                Text("2 fps").tag(2.0)
                Text("5 fps").tag(5.0)
                Text("10 fps").tag(10.0)
                Text("15 fps").tag(15.0)
                Text("30 fps").tag(30.0)
            }

            Toggle("Pin to all spaces", isOn: Binding(
                get: { WindowOverlay.pinToAllSpaces },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: "pinToAllSpaces")
                    tracker.updateAllSpaces()
                }
            ))
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
