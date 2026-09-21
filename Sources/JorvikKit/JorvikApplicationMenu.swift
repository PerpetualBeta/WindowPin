import AppKit

/// Builds the application menu — the first menu in the menu bar, the one AppKit
/// shows for whichever app is active.
///
/// A Jorvik menu-bar app is an accessory app (`LSUIElement`), so this menu is
/// never drawn: an accessory app has no menu bar of its own. It is built for one
/// reason only. AppKit dispatches key equivalents through `NSApp.mainMenu`, so
/// with no main menu Command+Q does not quit, and Command+X, Command+C,
/// Command+V and Command+A do nothing in the text fields of a settings window,
/// because the field editor is never sent the action.
///
/// The app used to get this menu for free. SwiftUI builds one for any `App`, and
/// `App` needs at least one scene, so every Jorvik menu-bar app declared a
/// `Settings { EmptyView() }` placeholder it never used — the settings window the
/// user sees is opened imperatively from the status-item menu. On macOS 26 and
/// later that placeholder is opened as a real window at launch: blank, titled
/// after the app, and roughly 900x450. Suppressing it needs `Scene`'s
/// `defaultLaunchBehavior`, which needs macOS 15.
///
/// So the `App` conformance went instead, and with it the scene that could open
/// the window at all. The apps now start from a plain `main.swift`, the same way
/// CopyLens, Tugboat and Lookout always have, and the menu is built here.
enum JorvikApplicationMenu {

    /// Installs the menu. Call from `applicationDidFinishLaunching`.
    @MainActor
    static func install() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName

        let bar = NSMenu()

        // The application menu. Quit is the only item that earns its place: the
        // rest of what SwiftUI put here (About, Services, Hide, the Settings
        // item the apps already suppressed) is either unreachable or duplicated
        // by the status-item menu, which is the menu the user actually sees.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)

        // Every item here is deliberately left without a target. A nil target
        // sends the action down the responder chain, which is what puts it in
        // front of the field editor of whichever text field has focus.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        // Capital Z is how AppKit spells Command+Shift+Z.
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu
        bar.addItem(editItem)

        NSApp.mainMenu = bar
    }
}
