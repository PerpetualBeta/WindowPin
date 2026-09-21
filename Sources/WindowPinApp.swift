import Cocoa

/// The entry point. Deliberately not a SwiftUI `App`.
///
/// `App` must vend at least one scene, and the only scene this app ever had was
/// a `Settings { EmptyView() }` placeholder it never opened — the settings
/// window the user sees comes from the status-item menu, via
/// `JorvikSettingsView.showWindow`. On macOS 26 and later that placeholder is
/// opened as a real window at launch: blank, titled after the app, roughly
/// 900x450. Removing the scene removes the window it could open.
///
/// `@main` on a type rather than top-level code in a `main.swift`, because
/// `AppDelegate` is `@MainActor` and top-level code is not isolated to it, so
/// constructing the delegate there does not compile.
@main
enum WindowPinMain {

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
