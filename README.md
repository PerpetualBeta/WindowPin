# WindowPin

A macOS utility that lets you pin any window as a floating, always-on-top overlay — like picture-in-picture for any app. Keep reference material, chat windows, or dashboards visible while you work.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/WindowPin/releases/latest/download/WindowPin.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/WindowPin/releases/latest)** — unzip and drag `WindowPin.app` to your Applications folder.

After installation:

1. Launch WindowPin — a pin icon appears in your menu bar
2. Grant the permissions when prompted (see [Permissions](#permissions) below)

## How It Works

WindowPin mirrors any window as a floating overlay that stays on top of everything else. The overlay is a live ScreenCaptureKit stream — it updates the moment the window's content changes (up to a configurable frame rate) and costs essentially nothing while the content is static.

Clicks and scrolls on the overlay are forwarded to the real window, so you can scroll a pinned document or click a button in it without leaving the app you're working in. Keyboard input always stays with your active app — to type into the pinned window, switch to it (⌘-click the overlay).

When you switch to the app that owns a pinned window, the overlay automatically drops behind the real window so you interact with the actual app — not the overlay.

## Pinning a Window

There are two ways to pin a window:

### Using the keyboard shortcut

1. Click the window you want to pin to bring it to the front
2. Press **⌃⌘P** (Ctrl+Cmd+P)
3. The window is now pinned — a live overlay appears on top of all other windows

Press the shortcut again to unpin.

### Using the menu

1. Click the window you want to pin to bring it to the front
2. Click the pin icon in the menu bar
3. The top item shows the frontmost window — click **Pin** next to it

## Unpinning

- **Keyboard shortcut**: Bring the pinned window to the front and press **⌃⌘P**
- **Menu**: Click the pin icon in the menu bar and click **Unpin** next to the window, or choose **Unpin All**
- **⌘-click the overlay**: Brings the real window to the front and hides the overlay behind it

Closed windows are automatically unpinned.

## Interacting with Overlays

| Action | Result |
|--------|--------|
| Click, drag, or right-click an overlay | Forwarded to the real window — buttons, links, and text selection work in place |
| Scroll on an overlay | Scrolls the real window |
| ⌘-click an overlay | Brings the real window to the front; overlay drops behind it |
| Type | Keyboard input is never forwarded — it stays with your active app |
| Switch to the pinned window's app | Overlay automatically drops behind the real window |
| Switch to a different app | Overlay floats back on top |

Forwarding can be turned off in Settings (**Interact through overlays**) — a plain click then switches to the real window instead.

## Menu Bar Icon

The pin icon in the menu bar changes to reflect the current state:

- **Empty pin**: No windows are pinned
- **Filled pin**: One or more windows are pinned

Click the icon to access:

- **Pin/Unpin** the frontmost window
- A list of all currently **pinned windows** (click to unpin)
- **Unpin All** — remove all pinned overlays
- **Settings…** — frame rate, overlay interaction, spaces, shortcut, and permissions
- **Check for Updates…** — manual Sparkle update check
- **Quit**

## Settings

### Maximum Frame Rate

Caps how fast the overlay can update. Frames are only captured when the window's content actually changes, so the default of **30 fps** costs essentially nothing for static content — lower it only if you want to limit CPU use while pinning video or animations.

### Interact Through Overlays

On by default: clicks and scrolls on an overlay are forwarded to the pinned window, and ⌘-click switches to the real window. When off, any click on an overlay switches to the real window.

### Pin to All Spaces

When enabled, pinned overlays appear on every Mission Control space. When disabled, they only appear on the space where they were created.

### Custom Keyboard Shortcut

Click **Change Shortcut** in the menu, then press your desired key combination. The shortcut must include at least one modifier key (⌘, ⌃, ⌥, or ⇧).

### Menu Bar Icon

- **Show icon in menu bar** — hide the menu-bar status icon while WindowPin keeps running; it remains reachable via its keyboard shortcut (Control+Command+P). The choice persists across launches, including login auto-start. *Shown only on macOS 14–15 — on macOS 26 (Tahoe) and later, use System Settings → Menu Bar, which provides this natively.*
- **Menu bar icon pill** — optional grey background for stronger contrast on busy or wallpaper-tinted menu bars (off by default)

If you've hidden the status icon and want it back, simply re-open WindowPin from your Applications folder — it reappears immediately.

All settings are saved automatically and persist across restarts.

### Updates

Updates are handled by [Sparkle](https://sparkle-project.org). WindowPin checks for new versions automatically once a day in the background; use **Check for Updates…** in the menu for an on-demand check.

## Permissions

WindowPin requires two macOS permissions:

### Accessibility (required)

Needed for the global keyboard shortcut, for forwarding clicks and scrolls to pinned windows, and for bringing windows to the front.

- Prompted automatically on first launch
- Grant in: **System Settings → Privacy & Security → Accessibility**
- Without this, the keyboard shortcut will not work

### Screen Recording (required)

Needed to capture window content for the live overlay.

- Prompted when you first pin a window
- Grant in: **System Settings → Privacy & Security → Screen Recording**
- Without this, overlays will appear blank

## Building from Source

WindowPin uses Swift Package Manager. No Xcode project is required.

```bash
cd ~/Desktop/WindowPin
gmake build
open .build/WindowPin.app
```

Requires GNU Make 4.x — `brew install make` installs it as `gmake`. The target is defined in the shared `release.mk` from `jorvik-release/`.

## Troubleshooting

### The keyboard shortcut doesn't work

Make sure WindowPin has **Accessibility** permission in System Settings → Privacy & Security → Accessibility. You may need to remove and re-add it if you've rebuilt the app.

### Overlays are blank

Grant **Screen Recording** permission in System Settings → Privacy & Security → Screen Recording. A restart of WindowPin may be required after granting.

### An overlay is stuck on screen

Click the pin icon in the menu bar and choose **Unpin All**, or quit WindowPin entirely — all overlays disappear when the app exits.

---

WindowPin is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
