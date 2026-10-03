# Eyes Only

Keeps chosen windows — or chosen browser tabs — visible to **you**, while screenshots, screen
recordings and screen sharing see a **black box** in their place.

It works on your Mac only. It sends nothing over the network and doesn't change other apps.
Requires macOS 14 (Sonoma) or later.

---

## Install

1. Open **Eyes-Only.dmg** and drag **Eyes Only** onto the **Applications** folder next to it.
   (Got the zip instead? Drag **Eyes Only.app** into Applications — or just open it, and it offers to
   move itself there.)
2. Open it from Applications: the first time, **right-click → Open**, then click **Open** again.
   (macOS asks because the app isn't from the App Store. You only need to do this once.)
3. macOS asks for **Screen Recording** permission. Turn on **Eyes Only** in
   System Settings → Privacy & Security → Screen & System Audio Recording.
4. **Quit the app and open it again.** An eye icon appears in the menu bar.
5. Optional: **Settings → General → Open at login**, so it's always running.

If it keeps asking for permission, see *Troubleshooting* below.

## Use

Click the **eye icon** in the menu bar:

- **Tick a window** to protect it. Untick it to stop. The number next to the eye shows how many
  windows and tabs are protected.
- Hover an app in the list to see its window's title.
- **Stop All** turns off everything you ticked by hand (apps and sites from Settings stay on).
- **Pause Auto-Protection** turns off the apps and sites from Settings for now (your lists are
  kept); **Resume Auto-Protection** turns them back on. They're always back on when the app starts.
- **Settings… (⌘,)**
  - **Apps** — tick an app to protect *every* window of it automatically, whenever it opens.
  - **Browser** — protect individual tabs or whole sites (see below).
  - **General** — open at login, "Always keep covers on top" (off is recommended), diagnostics.

To check it's working, take a screenshot of an area (⇧⌘4, then drag) over a protected window — it
should be black.

**Good to know:** Eyes Only hides windows from captures of the *screen* — screenshots, screen
recordings, sharing your whole screen. It can't hide a window from a capture of *that window itself*
(⇧⌘4 then Space, or "share this window" in a video call), because those read the window directly.

## Protecting browser tabs (Chrome, Edge, Brave, Arc, Vivaldi, Chromium)

Open **Settings → Browser** and follow the steps there to add the small browser extension
(one time). Then:

- Your tabs appear in the eye menu under **"Google Chrome tabs"** (or your browser's name) —
  tick a tab to protect it.
- Or add a site under **Protected sites** (e.g. `mail.google.com`) to protect every tab
  showing it, automatically.

Safari isn't supported.

## Troubleshooting

**It keeps asking for Screen Recording permission** — double-click **Fix Permissions.command**
(if macOS blocks it: right-click → Open). Then turn the permission on again, quit the app, and
open it once more.

**The tab list doesn't appear** — Settings → Browser should say "✓ Connected". If not, make
sure the extension is turned on in your browser's Extensions page, and that the app is running.

**Something else isn't working** — open **Settings → General**, turn on **Detailed diagnostics
log**, make the problem happen again, then click **Show Log File** and send that file. The log
contains app names, window sizes and events only — never window titles, web addresses or anything
that's on your screen. Turn it off again afterwards.

## Privacy

Eyes Only has no network code: it never sends anything anywhere, has no analytics and doesn't check
for updates. What it sees of your screen stays in memory, only to draw the protected windows for you,
and is never saved. Your settings (protected apps and sites) stay on your Mac. The browser extension
tells the app — on your Mac only — which tabs are open; it can see incognito tabs only if you allow it
in your browser.

## Uninstall

Quit the app (eye icon → Quit), then delete it from Applications. To also remove its leftovers:
`~/Library/Application Support/Eyes Only` and `~/Library/Logs/Eyes Only`.
