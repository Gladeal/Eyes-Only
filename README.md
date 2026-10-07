# Eyes Only

**Keep chosen windows and browser tabs private in screenshots, screen recordings and screen sharing — while you keep seeing and using them normally.**

Eyes Only is a small macOS menu-bar app. Pick a window (or a browser tab, or a whole app, or a website), and anything that captures your screen sees a black box where it is. On your own display, the window looks and works exactly as before.

Useful when you share or record your screen and don't want a chat, an inbox, a dashboard or a document to show up in it.

- Runs entirely on your Mac — no network code, no analytics, no accounts.
- Native: menu-bar app, macOS Settings-style window, Stage Manager and multiple-display aware.
- macOS 14 (Sonoma) or later, Apple silicon and Intel.

---

## What it protects — and what it doesn't

| Capture | Protected? |
|---|---|
| Screenshots of the screen or an area (⇧⌘3, ⇧⌘4 drag) | ✅ black box |
| Screen recordings of the screen (⇧⌘5, QuickTime, OBS display capture, …) | ✅ |
| Sharing your whole screen (Zoom, Meet, Teams, Slack, …) | ✅ |
| Tools that take periodic screenshots of the screen | ✅ |
| Capturing **that one window** on purpose (⇧⌘4 then Space, "share a window" in a call, window capture in OBS) | ❌ — these read the window's own image directly, whatever is drawn over it |
| Someone looking at your screen, or photographing it | ❌ — it's still on your display, by design |

## Features

- **Protect a window** — tick it in the menu-bar menu. Several at once, on any display.
- **Protect apps** — every window of a chosen app, automatically, whenever it opens (Settings → Apps).
- **Protect tabs and sites** in Chrome, Edge, Brave, Arc, Vivaldi and Chromium — tick a tab in the menu, or add a site (`mail.google.com`, `example.com/path`) to protect every tab showing it. Needs the small extension in [`BrowserExtension/`](BrowserExtension). Safari isn't supported.
- **Pause / resume** all protection at once, **Stop All** for the ones you ticked.
- **Keyboard shortcuts** for pausing, protecting the front window or tab, and more — set your own in Settings → Shortcuts.
- **Stage Manager**, Mission Control, full-screen Spaces and window snapping are handled; in captures, a protected window's Stage Manager thumbnail and Mission Control tile are black too.
- **Live previews** (on by default): to you, a protected window's Stage Manager thumbnail, Mission Control tile and their animations look normal; captures still show them black. Costs some CPU while a protected window is in the strip or Mission Control is open — turn it off in Settings → General.
- **Open at login**, and an optional detailed diagnostics log for troubleshooting.

## Install

Download the latest `Eyes-Only.dmg` from [Releases](https://github.com/Gladeal/Eyes-Only/releases/latest), open it and drag **Eyes Only** onto **Applications**. Then:

1. Open it from Applications. The app isn't notarized by Apple yet, so the first time: **right-click → Open**, then **Open**.
2. Allow **Screen Recording** when macOS asks (System Settings → Privacy & Security → Screen & System Audio Recording), then quit and reopen the app.
3. An eye icon appears in the menu bar. That's it.

For browser tabs: Settings → Browser walks you through adding the extension (Developer mode → Load unpacked).

## How it works

Eyes Only uses only public macOS APIs.

1. **A black cover.** A borderless, click-through window is placed over the protected window. It is *included* in screen captures, so a capture of the screen shows black there.
2. **A live copy for you.** A second window sits on top of it, showing a live copy of the protected window captured with [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit). This window is marked `sharingType = .none`, so screen captures *leave it out* — but your display shows it. You see your window; captures see the black cover beneath.
3. **Tracking.** The covers follow the window as it moves, resizes, goes into the Stage Manager strip or to another display. Tracking runs at the display's refresh rate only while something can move, and slows right down otherwise.
4. **Browser tabs.** The extension reports which tabs are open and which is active to the app, over Chrome's [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) — the app's own executable acts as the messaging host and relays to the running app through a local socket only it can use. When a protected tab is active, its window is covered.

## Privacy and security

- **No network access.** The app and the extension never send or receive anything over the network.
- **Nothing on your screen is stored.** Captured frames live in memory only, to draw the live copy. For live previews and Stage Manager / Mission Control animations, the app also captures the display itself (without its own windows) while a protected window is in the strip, animating, or Mission Control is open — same rule: memory only, never saved or sent.
- **Settings stay local** (macOS user defaults): your protected apps and sites, and a few switches.
- **The log** (`~/Library/Logs/Eyes Only/`) has app names, window sizes and events — never window titles, web addresses or screen content — and stays on your Mac unless you send it to someone.
- **The browser link** accepts only the app's own relay; other programs are refused. The extension only talks to the app on the same Mac; it sees incognito tabs only if you allow it.
- **Hardened runtime** is enabled, so other code can't be injected into the app (it holds the Screen Recording permission).

Found a security problem? Please report it privately rather than in a public issue.

## Build from source

Requirements: macOS 14+, Xcode or the Command Line Tools (Swift 6).

```sh
Scripts/make-signing-identity.sh   # once: a local self-signed code-signing identity, so the
                                   # Screen Recording permission survives rebuilds
Scripts/build.sh                   # development build → build/Eyes Only.app (full diagnostics log)
Scripts/make-release.sh            # release build → Eyes-Only.dmg and Eyes-Only.zip
Scripts/test.sh                    # run the tests
```

It's a Swift package (`Package.swift`), so `swift build` and opening the folder in Xcode work too; `Scripts/build.sh` wraps the executable into a signed, universal app bundle.

| Folder | What's in it |
|---|---|
| `Sources/EyesOnly/App` | Startup, the menu-bar menu, and the `Controller` that runs everything (one shared tick for all protected windows) |
| `Sources/EyesOnly/Protection` | One `Session` per protected window: its capture, its cover (`Overlay`), stacking and Stage Manager handling |
| `Sources/EyesOnly/Browser` | The link to the browser extension (native-messaging host and local socket) |
| `Sources/EyesOnly/Settings` | Saved settings and the Settings window |
| `Sources/EyesOnly/Support` | Small shared helpers: window geometry, timeouts, the diagnostics log |
| `Tests/EyesOnlyTests` | Tests for the parts that don't need a screen: site rules, frame geometry, Stage Manager preview shapes |
| `BrowserExtension` | The Chromium extension (Manifest V3, plain JavaScript) |
| `Packaging` | App icon, and the read-me and permission fixer that go into the release |
| `Scripts` | Build, test, release, signing identity and icon scripts |

### How the code fits together

- **`EyesOnlyApp`** starts the menu-bar app — or, when a browser starts the executable as its messaging host, just relays the extension's messages (`Browser/NativeHost.swift`).
- **`Controller`** is the app: the menu, the browser link, always-protected apps, and one `Session` per protected window. It runs a single shared **tick** — at the display's refresh rate while anything can be moving, 10 times a second otherwise. Each tick reads the system's window list once (`WindowInfo`) and hands it to every session.
- **`Session`** protects one window. Its `Overlay` holds the two cover windows (the capturable black one, and the live copy that captures leave out). Its ScreenCaptureKit stream delivers frames through `FrameSink` to `receive`, which draws them; `tick` keeps the covers on the window — position, stacking, Stage Manager and Mission Control. The capture slows down when the window can't be seen at full size, and restarts itself if it stalls. While the window is in the Stage Manager strip, animating, or Mission Control is open, a capture of the display (`Session+ScreenFeed`) supplies the copy instead — macOS draws those states itself, so only the screen has them.
- **Browser tabs:** the extension reports windows and tabs → the relay → `BrowserBridge` → `Controller+Tabs`, which decides which browser windows need a cover right now and starts or pauses their sessions.
- **Settings** are a few `UserDefaults` keys (`Settings`). The Settings window's panes talk to the controller through closures.
- **Logging:** `log` for events (always written), `logDetail` for detail that's only written with detailed diagnostics on. Never window titles, web addresses or screen content.

The browser extension's ID is fixed by the public key in its manifest; the matching private key is not part of this repository.

## Known limitations

- Window-specific captures aren't blocked (see the table above).
- Safari isn't supported for tab protection.
- DRM-protected video (e.g. some streaming sites) can appear black in the live copy too, because macOS won't let it be captured.
- The black cover over a Stage Manager strip thumbnail floats above other windows. With live previews you see those windows normally, but captures show the black cover over the part of them that overlaps the thumbnail.
- Not yet signed and notarized by Apple, so macOS warns on first launch.

## License

[GNU Affero General Public License v3.0](LICENSE). You may use, study, change and share Eyes Only. Modified versions — whether you distribute them or let people use them over a network — must stay under the same license, with their source available to their users.
