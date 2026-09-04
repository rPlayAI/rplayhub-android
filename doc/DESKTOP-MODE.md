# Desktop Mode — Android's desktop in a window of its own

Desktop Mode puts an Android phone's *desktop* — taskbar, launcher, windowed apps — in a window
on the Mac, on a display the phone does not have. The phone's own screen keeps mirroring in the
main window; the desktop is a second, independent stream. One click (Device ▸ Desktop Mode,
⌘D, or the device row's context menu).

This document is the mechanism. The single-app variant — one activity on a bare virtual display
— is the same machinery with one flag flipped, and has its own note: `APP-ON-VIRTUAL-DISPLAY.md`.

## What the user gets

- A window titled after the device, showing Android's desktop at 1920×1080 (240 dpi). Android
  draws its taskbar along the bottom and its launcher; apps open there as windows, the way they
  do on a tablet in desktop mode or on an external display.
- The phone's mirror carries on untouched in the main window; both are live at once.
- The window opens "naked": the picture edge to edge under a transparent title bar. Nearing the
  top edge fades in the traffic lights and three controls — **Wake** (wakeup + dismiss keyguard),
  **Screenshot** and **Record**.
- Closing the window destroys the virtual display on the phone. Nothing is left running.
- Asking for Desktop Mode again while a desktop window exists brings that window forward; there
  is only ever one desktop per device.

## How it works, end to end

```
Mac                                       phone (agent, shell uid)
 ─ control channel: CreateNewDisplay ───▶  DisplayManagerGlobal.createVirtualDisplay(
      1920×1080, 240 dpi, decorations=1       flags = PUBLIC | OWN_CONTENT_ONLY | SUPPORTS_TOUCH
                                                    | ROTATES_WITH_CONTENT | TRUSTED | OWN_FOCUS
                                                    | SHOULD_SHOW_SYSTEM_DECORATIONS)
                                           attach keep-alive surface; start streaming display N
 ◀─ video packets tagged displayId = N ──   (the ordinary mirror path, one channel for all displays)
 FusionWindow(N): own MirrorView, own decoder
 touches/keys on that window ───────────▶  injected with displayId = N
 window closed: DestroyNewDisplay ──────▶  stop streaming, release the display
```

### 1. The display is created by the agent, not by adb

There is no shell command that creates a standalone virtual display, so this is an addition to
Google's screen-sharing agent (`refs/studio/…/VirtualDisplayFactory.java`, plus two control
messages, types 120 `CreateNewDisplay` and 121 `DestroyNewDisplay`; see
`refs/studio/PROVENANCE.md`). The agent runs as the shell user through `app_process`, and shell
holds `ADD_TRUSTED_DISPLAY`, which is what the flag set below needs.

The display is a *standalone* display — a display of its own that apps can be launched onto —
not a mirror of the phone's screen. scrcpy calls the same idea `--new-display`.

`DisplayManagerGlobal.createVirtualDisplay` is reached through a reflected
`VirtualDisplayConfig`; that path is what makes the owner-uid check accept shell.

### 2. The flags, and the two that are deliberately missing

| flag | why |
|---|---|
| `PUBLIC` | apps may be launched onto it |
| `OWN_CONTENT_ONLY` | shows its own content, never a mirror of display 0 |
| `SUPPORTS_TOUCH` | injected touches with this display id are accepted |
| `ROTATES_WITH_CONTENT` | the display turns with an app that wants landscape |
| `TRUSTED` | input and the system decorations are allowed on it |
| `OWN_FOCUS` | it has its own focused window, independent of the phone's screen |
| `SHOULD_SHOW_SYSTEM_DECORATIONS` | **Desktop Mode's flag**: Android draws the taskbar and launcher on it. Off for a single app's window. |

If the full set is rejected (privileged flag values vary by release), the agent retries with
`PUBLIC | OWN_CONTENT_ONLY | SUPPORTS_TOUCH | TRUSTED`.

`OWN_DISPLAY_GROUP` and `ALWAYS_UNLOCKED` are **not** requested, although they look like exactly
what a second desktop wants (its own power state, no keyguard). With either, the capture of the
display comes back solid black — a DisplayManager mirror lives in the default display group and
cross-group content is withheld — and the SurfaceControl alternative aborts on API 34+. So the
display shares the phone's power group, and the agent keeps the phone awake while the display
exists instead (the mirror's wake-key ticker). Practical consequence: the desktop sleeps when the
phone sleeps, which is why the window has a Wake button and why opening Desktop Mode wakes the
phone first.

### 3. The keep-alive surface

A virtual display with no surface has its display *device* OFF: `DisplayPowerController` holds a
sleep token for it and every activity launched onto it is paused at once — the desktop renders
nothing. Nothing else powers it on (not content, not input, not `requestDisplayPower`), but
attaching a surface does. So the agent attaches a consumed `ImageReader` at quarter resolution
as a keep-alive surface: it exists only so the device is ON; every image it produces is closed
unread. The stream itself captures the display's layer stack through the agent's own mirror
display, unaffected.

Do not attach the encoder's input surface to the virtual display directly — that loops the
codec (the display's content is the encoder's own output surface).

### 4. Streaming: one channel, many displays

Google's agent already multiplexes every started display on the single video channel; each
packet header carries its display id. The host keeps a decode pipeline per display id
(`VideoStream`), so the phone's screen and the desktop decode independently. A new display id
arriving in the stream is what opens the window: `FusionWindow` is a self-contained naked window
with its own `MirrorView` bound to that id; the main window's mirror never changes.

Requests are queued (`pendingFusion`) and answered in the order the display ids arrive, so
Desktop Mode and several app windows can be asked for back to back without an agent bounce.

### 5. Input

Touches and keys from the desktop window are ordinary agent control messages with the display
id set to the virtual display's. `OWN_FOCUS` is what lets the desktop hold keyboard focus
independently of whatever the phone's own screen is doing.

### 6. Screenshot and recording

- **Screenshot** goes through `screencap -d <id>`, which wants the *physical* SurfaceFlinger id,
  not the logical one the app tracks. It is resolved by name:
  `dumpsys SurfaceFlinger --display-id | grep rplayhub.display`.
- **Recording** is host-side (`FrameRecorder`, decoded frames → `AVAssetWriter` mp4).
  Android's `screenrecord --display-id` refuses virtual displays outright — and this also
  removes its three-minute cap.

### 7. Teardown

Closing the window sends `DestroyNewDisplay`; the agent stops that display's stream and
releases it. Switching devices, stopping mirroring or quitting discards every fusion window and
its display the same way, so nothing keeps streaming invisibly and the phone is not left with
stray displays.

## Why this and not the alternatives

- **A shell-uid overlay window** on the phone is rejected by WindowManager (`Unknown pid
  uid=2000`): the agent has no window session, so nothing can be drawn on the phone from shell.
  A separate display sidesteps that entirely.
- **`am start --display` alone** needs a display to exist; Android provides none from adb.
- **Mirroring display 0 and cropping** is not a desktop — it is the phone's screen.

## Test hooks

`--env RPLAYHUB_FUSE=com.android.settings,com.android.chrome` opens those apps on virtual
displays at launch (one window each). Desktop Mode and app windows can be open together with the
phone's mirror; verified on a Pixel 9a with Settings + Chrome on two displays and the mirror all
live.
