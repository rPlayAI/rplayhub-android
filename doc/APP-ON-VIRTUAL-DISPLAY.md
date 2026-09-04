# One app on a virtual display — an Android app in a Mac window

Pick an app and it opens in a window of its own on the Mac: a bare display with nothing but that
app on it — no taskbar, no launcher, no phone chrome — while the phone's own screen keeps
mirroring, untouched, in the main window. Several apps, several windows. In the code this is
"fusion"; in the UI it is **Open on Virtual Display** (Apps tab, right-click), **Fuse Selected
App** (⇧⌘F), and the app row's drag-out target.

It is Desktop Mode (`DESKTOP-MODE.md`) with one flag off and one extra step: the display is
created *without* system decorations, and the host launches the chosen activity onto it. Read
that note for the display machinery; this one covers what differs.

## What the user gets

- A naked window titled with the app's real launcher label, showing just that app. Android
  lays the app out for the display's size (1920×1080 at 240 dpi), so phone-only apps show their
  tablet/landscape layout where they have one.
- The window's title-bar controls (on hover): Wake, Screenshot, Record.
- Opening an app that already has a window brings that window forward instead of making a
  second display — the app's task would only move there anyway.
- Closing the window destroys the display; the app's task ends with it.

## The sequence

```
Mac                                              phone
 wake the phone (input keyevent 224; wm dismiss-keyguard)
 CreateNewDisplay 1920×1080, 240 dpi, decorations=0 ──▶ virtual display N, no taskbar/launcher
 ◀── first packets tagged displayId = N              (the window opens on this)
 cmd package resolve-activity --brief -c LAUNCHER <pkg> | tail -1
 am start --display N -n <component> ─────────────▶ the activity starts ON display N
 AppLabel (app_process, from the agent jar) ──────▶ the launcher label + icon for the title
```

### Why the *host* launches the app

`startActivity` from inside the agent is denied to shell, and `monkey` cannot target a display.
So the host resolves the launcher activity with `cmd package resolve-activity --brief` and starts
it with `am start --display N -n <component>` over adb. Display 0 falls back to the plain
`monkey -p <pkg> -c android.intent.category.LAUNCHER 1` launch.

### Why no decorations

`SHOULD_SHOW_SYSTEM_DECORATIONS` is what gives Desktop Mode its taskbar and launcher. Under a
single app it is clutter along the bottom of the window, so an app display is created without
it. Everything else — `PUBLIC`, `OWN_CONTENT_ONLY`, `SUPPORTS_TOUCH`, `ROTATES_WITH_CONTENT`,
`TRUSTED`, `OWN_FOCUS`, the keep-alive surface — is the same as Desktop Mode's.

### The window's title

A package id is not a name. `AppLabel` is a small `main` in the agent jar, run through
`app_process`, that prints `label<TAB>base64 PNG` per package in one round trip — the launcher's
own label and icon, adaptive and obfuscated icons included. The window opens with a guess
("com.google.android.youtube" → "Youtube") and is retitled when the label arrives.

A trap here: the agent deletes its own jar from `/data/local/tmp/.studio` once it is up, so
anything run from that jar afterwards aborts. The tools run from a second copy the host keeps at
`/data/local/tmp/.rplayhub/`.

### Power

The display shares the phone's power group (see Desktop Mode for why the alternative captures
black). If the phone sleeps, the app pauses; the agent keeps the phone awake while the display
exists, the phone is woken before the display is requested, and the window has a Wake button.

### Input

Clicks and keys on the app's window are injected with that display's id; `OWN_FOCUS` gives the
display its own focused window, so typing into the app does not depend on what the phone's
screen has focused.

### Screenshot and recording

Same as Desktop Mode: `screencap -d` with the physical SurfaceFlinger id resolved by name, and
host-side recording (Android's `screenrecord` cannot capture a virtual display at all).

## Getting content out: "Send to Mac"

A natural wish, once an app is in a Mac window, is to drag a photo out of it onto the desktop.
Android delivers a drag's content URI only on **drop**, never at drag start, so a live cross-window
drag cannot be built on shell privileges. The supported path is share-to-send: the companion APK
(`helper/`, "rPlayHub Share") is a share-sheet target that copies shared items into its outbox
(`/sdcard/Android/data/ai.rplay.rplayhub.share/files/outbox/<batch>/`, a `.ready` marker written
last, no runtime permissions needed — shell can read that directory). The Mac polls the outbox
while a session is live, pulls each batch to `~/Downloads/rPlayHub Shared/`, deletes it on the
phone, and shows a **draggable thumbnail tray** on the app's window; the thumbnail drags out as
the real file. Google Photos ▸ Share ▸ Send to Mac ▸ drag the photo to the desktop, verified end
to end.

## Limits

- Android 5.0–7.1 devices (the legacy agent path) have no virtual displays; there the picture is
  only ever the real screen.
- One live device session at a time today; the app windows belong to the current device and
  are discarded on a switch.
- An app that refuses to run on a secondary display (rare: `android:resizeableActivity=false`
  with a display-restricted manifest) starts on display 0 instead; Android decides that, not us.
