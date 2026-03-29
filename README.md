# WindowPin

A macOS utility that lets you pin any window as a floating, always-on-top overlay — like picture-in-picture for any app. Keep reference material, chat windows, or dashboards visible while you work.

## Requirements

- macOS 14 (Sonoma) or later

## Installation

1. Double-click `WindowPin.app` to launch it (or build from source — see below)
2. A pin icon appears in your menu bar
3. Grant the permissions when prompted (see [Permissions](#permissions) below)

## How It Works

WindowPin captures a live image of any window and displays it as a floating overlay that stays on top of everything else. The overlay updates continuously at a configurable frame rate.

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
- **Click the overlay**: Clicking a pinned overlay brings the real window to the front and hides the overlay behind it

Closed windows are automatically unpinned.

## Interacting with Overlays

| Action | Result |
|--------|--------|
| Click an overlay | Brings the real window to the front; overlay drops behind it |
| Drag an overlay | Repositions the overlay on screen |
| Switch to the pinned window's app | Overlay automatically drops behind the real window |
| Switch to a different app | Overlay floats back on top |

## Menu Bar Icon

The pin icon in the menu bar changes to reflect the current state:

- **Empty pin**: No windows are pinned
- **Filled pin**: One or more windows are pinned

Click the icon to access:

- **Pin/Unpin** the frontmost window
- A list of all currently **pinned windows** (click to unpin)
- **Unpin All** — remove all pinned overlays
- **Change Shortcut** — set a custom keyboard shortcut
- **Capture Rate** — adjust how often the overlay refreshes
- **Pin to All Spaces** — make overlays visible across all Mission Control spaces
- **Quit**

## Settings

### Capture Rate

Controls how frequently the overlay image refreshes. Available rates:

| Rate | Best for |
|------|----------|
| 0.5 fps | Static content (documents, reference pages) |
| **1 fps** (default) | General use |
| 2–5 fps | Slowly changing content (dashboards, chat) |
| 10–30 fps | Video or rapidly updating content (higher CPU usage) |

### Pin to All Spaces

When enabled, pinned overlays appear on every Mission Control space. When disabled, they only appear on the space where they were created.

### Custom Keyboard Shortcut

Click **Change Shortcut** in the menu, then press your desired key combination. The shortcut must include at least one modifier key (⌘, ⌃, ⌥, or ⇧).

All settings are saved automatically and persist across restarts.

## Permissions

WindowPin requires two macOS permissions:

### Accessibility (required)

Needed for the global keyboard shortcut and for bringing windows to the front.

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
./build.sh
open _BuildOutput/WindowPin.app
```

The build script runs `swift build -c release`, then assembles the `.app` bundle in `_BuildOutput/` with the executable, icon, and Info.plist.

## Troubleshooting

### The keyboard shortcut doesn't work

Make sure WindowPin has **Accessibility** permission in System Settings → Privacy & Security → Accessibility. You may need to remove and re-add it if you've rebuilt the app.

### Overlays are blank

Grant **Screen Recording** permission in System Settings → Privacy & Security → Screen Recording. A restart of WindowPin may be required after granting.

### An overlay is stuck on screen

Click the pin icon in the menu bar and choose **Unpin All**, or quit WindowPin entirely — all overlays disappear when the app exits.

---

WindowPin is provided by [Jorvik Software](https://jorviksoftware.cc/). If you find it useful, consider [buying me a coffee](https://jorviksoftware.cc/donate).
