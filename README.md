# WindowPin

A macOS utility that lets you pin any window as a floating, always-on-top overlay — like picture-in-picture for any app. Keep reference material, chat windows, or dashboards visible while you work.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

Two formats on every release — both signed and notarised, pick whichever suits:

- **[Installer (`.pkg`)](https://github.com/PerpetualBeta/WindowPin/releases/latest/download/WindowPin.pkg)** — recommended for first-time installs. Double-click to run; macOS Installer places the app in `/Applications` without quarantine or App Translocation.
- **[Download (`.zip`)](https://github.com/PerpetualBeta/WindowPin/releases/latest)** — unzip and drag `WindowPin.app` to your Applications folder.

Or install it with [Homebrew](https://brew.sh):

```sh
brew install --cask perpetualbeta/jorvik/windowpin
```

After installation:

1. Launch WindowPin — a pin icon appears in your menu bar
2. Grant the permissions when prompted (see [Permissions](#permissions) below)

## How It Works

WindowPin mirrors any window as a floating overlay that stays on top of everything else. The overlay is a live ScreenCaptureKit stream — it updates the moment the window's content changes (up to a configurable frame rate) and costs essentially nothing while the content is static.

What you can do with an overlay depends on your macOS version, because macOS 27 changed what one app may do to another's windows.

**On macOS 27 and later**, you can scroll a pinned window from wherever you are working, and the pane you point at is the one that scrolls. A click takes you to the real window rather than pressing something inside it. See [Interacting with Overlays](#interacting-with-overlays) for what this does and does not cover.

**On macOS 14 to 26**, clicks and scrolls are both forwarded to the real window, so you can scroll a pinned document or click a button in it without leaving the app you're working in.

Keyboard input always stays with your active app on every version — to type into a pinned window, switch to it.

When you switch to the app that owns a pinned window, the overlay automatically drops behind the real window so you interact with the actual app — not the overlay.

## Pinning a Window

There are two ways to pin a window:

### Using the keyboard shortcut

1. Click the window you want to pin to bring it to the front
2. Press `control` `command` `P`
3. The window is now pinned — a live overlay appears on top of all other windows

Press the shortcut again to unpin.

### Using the menu

1. Click the window you want to pin to bring it to the front
2. Click the pin icon in the menu bar
3. The top item shows the frontmost window — click **Pin** next to it

## Unpinning

- **Keyboard shortcut**: Bring the pinned window to the front and press `control` `command` `P`
- **Menu**: Click the pin icon in the menu bar and click **Unpin** next to the window, or choose **Unpin All**
- **Click the overlay**: Brings the real window to the front and hides the overlay behind it. On macOS 14 to 26 this is `command`-click, because a plain click is forwarded to the window instead

Closed windows are automatically unpinned.

## Interacting with Overlays

### On macOS 27 and later

| Action | Result |
|--------|--------|
| Scroll on an overlay | Scrolls the pinned window, under the pointer, without changing which app you are working in |
| Click an overlay | Takes you to the real window and brings its app forward |
| Type | Keyboard input is never sent to the pin — it stays with your active app |
| Switch to the pinned window's app | Overlay automatically drops behind the real window |
| Switch to a different app | Overlay floats back on top |

Scrolling can be turned off in Settings (**Interact through overlays**). Clicking always takes you to the real window.

**What scrolling does not cover.** WindowPin scrolls the pinned window by setting its scroll position through macOS's accessibility interface, which means the app has to offer one. Most Mac apps do, including Finder, Mail, Safari and Preview. Apps built on Electron or Chromium frequently do not, and a window that offers nothing scrollable simply will not scroll. Nothing else about the pin is affected.

**Why clicking cannot press things any more.** On macOS 27 an app may no longer deliver a click into another app's window: the click arrives but the system places it in the corner of the window rather than where you aimed, so it reaches nothing. Every published and unpublished route to do otherwise was measured and none works. Pressing controls through the accessibility interface instead was rejected deliberately — it would activate whatever you happened to point at, which is not the same thing as clicking it.

### On macOS 14 to 26

| Action | Result |
|--------|--------|
| Click, drag, or right-click an overlay | Forwarded to the real window — buttons, links, and text selection work in place |
| Scroll on an overlay | Scrolls the real window |
| `command`-click an overlay | Brings the real window to the front; overlay drops behind it |
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

On by default.

On **macOS 27 and later** this controls scrolling: on, a scroll on an overlay scrolls the pinned window; off, it does nothing. Clicking takes you to the real window either way.

On **macOS 14 to 26** it controls both: on, clicks and scrolls are forwarded to the pinned window and `command`-click switches to the real window; off, any click on an overlay switches to the real window.

### Pin to All Spaces

When enabled, pinned overlays appear on every Mission Control space. When disabled, they only appear on the space where they were created.

### Custom Keyboard Shortcut

Click **Change Shortcut** in the menu, then press your desired key combination. The shortcut must include at least one modifier key (`command`, `control`, `option`, or `shift`).

**Clear** removes the shortcut entirely. With none bound, nothing is intercepted, and pinning is still available from the menu-bar icon.

### Menu Bar Icon

- **Show icon in menu bar** — hide the menu-bar status icon while WindowPin keeps running; it remains reachable via its keyboard shortcut, if one is bound. If you have cleared that too, re-open WindowPin from Applications to bring the icon back. The choice persists across launches, including login auto-start. *Shown only on macOS 14–15 — on macOS 26 (Tahoe) and later, use System Settings → Menu Bar, which provides this natively.*
- **Menu bar icon pill** — optional grey background for stronger contrast on busy or wallpaper-tinted menu bars (off by default)

If you've hidden the status icon and want it back, simply re-open WindowPin from your Applications folder — it reappears immediately.

All settings are saved automatically and persist across restarts.

### Updates

Updates are handled by [Sparkle](https://sparkle-project.org). WindowPin checks for new versions automatically once a day in the background; use **Check for Updates…** in the menu for an on-demand check.

## Permissions

WindowPin requires two macOS permissions:

### Accessibility (required)

Needed for the global keyboard shortcut, for scrolling pinned windows, and for bringing windows to the front.

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

The build is driven by the shared [`release.mk`](https://github.com/PerpetualBeta/jorvik-release) Make include, so `jorvik-release` has to be checked out **beside this repo** — the Makefile looks for it at `../jorvik-release/`. macOS ships GNU Make 3.81 as `make`, which is too old, so `gmake` comes from [Homebrew](https://brew.sh).

```bash
brew install make   # GNU Make 4+, if you do not already have gmake
git clone https://github.com/PerpetualBeta/jorvik-release.git
git clone https://github.com/PerpetualBeta/WindowPin.git
cd WindowPin
gmake build
open.build/WindowPin.app
```

## Troubleshooting

### The keyboard shortcut doesn't work

Make sure WindowPin has **Accessibility** permission in System Settings → Privacy & Security → Accessibility. You may need to remove and re-add it if you've rebuilt the app.

### Overlays are blank

Grant **Screen Recording** permission in System Settings → Privacy & Security → Screen Recording. A restart of WindowPin may be required after granting.

### An overlay is stuck on screen

Click the pin icon in the menu bar and choose **Unpin All**, or quit WindowPin entirely — all overlays disappear when the app exits.

---

WindowPin is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
