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

## Implementation

### The agent (device side)

The agent is Google's screen-sharing agent from Android Studio (`refs/studio/`), built by
`tools/build-agent.sh` and pushed to `/data/local/tmp/.studio/`, run as the shell user through
`app_process`. It is C++ (JNI into the framework's hidden APIs) with a few Java helpers. Our
additions for standalone displays are marked "rPlayHub" in the source and listed in
`refs/studio/PROVENANCE.md`:

| piece | file | role |
|---|---|---|
| `CreateNewDisplayMessage` (type 120), `DestroyNewDisplayMessage` (121) | `control_messages.{h,cc}` | the two control messages, base128-encoded like all the others |
| dispatch | `controller.cc` | `Agent::CreateNewDisplay(width, height, dpi, decorations)` / `Agent::DestroyNewDisplay(id)` |
| `Agent::CreateNewDisplay` | `agent.cc` | refuses below API 34; creates the display through `DisplayManager::CreateNewDisplay` (JNI → `VirtualDisplayFactory.java`), keeps it in `new_displays_`, nudges its power state (`RequestDisplayPower`), starts a shell loop that sends `input keyevent 224` (WAKEUP) every 15 s for as long as the agent process lives, then `StartVideoStream(id)` |
| `VirtualDisplayFactory.java` | Java | `DisplayManagerGlobal.createVirtualDisplay` through a reflected `VirtualDisplayConfig` (the path whose owner-uid check accepts shell), the flag set from the table above, the quarter-resolution `ImageReader` keep-alive surface |
| streaming | `display_streamer.cc` | a display created here is streamed by the **generic secondary-display path**: the streamer makes its own *mirror* capture display of the standalone one and hands the encoder's input surface (`AMediaCodec_createInputSurface`, API 26) to that — exactly as for a physical secondary display. Rendering the encoder surface straight into the standalone display was tried and sends the codec into a configure/-10000 restart loop |
| `Agent::DestroyNewDisplay` | `agent.cc` | stops that display's streamer first (it holds the display), then releases the display |

Why the wake ticker: the display shares the phone's power group (see "the two flags that are
deliberately missing"), so every activity on it pauses the moment the phone sleeps. WAKEUP
every 15 s also resets the screen timeout, so the phone stays awake for as long as a display
exists. The loop watches the agent's pid and dies with it.

### The protocol

Everything rides on the agent's ordinary sockets — no new channel:

- **Control channel** (host → agent, base128 varints, `ControlMessages.swift` ↔
  `control_messages.cc`):
  - `CreateNewDisplay`: `int32 type=120, int32 width, int32 height, int32 dpi, int32 decorations`
    (1 = Desktop Mode's taskbar and launcher, 0 = a bare display for one app).
  - `DestroyNewDisplay`: `int32 type=121, int32 display_id`.
  - Nothing comes back for the create; the display announces itself in the video stream.
- **Video channel** (agent → host): one socket for every display. Each packet is a 44-byte
  little-endian header followed by an Annex-B H.264 access unit:

      int32  display_id            ← which display this packet belongs to
      int32  display_width, display_height
      uint8  display_orientation, display_orientation_correction   // quadrants
      int16  flags                 // round / bit-rate reduced / camera
      int32  bit_rate
      uint32 frame_number
      int64  origination_timestamp_us
      int64  presentation_timestamp_us   // 0 = config packet (SPS/PPS)
      int32  packet_size

  Geometry travels in every header, so a display's size and rotation need no side channel: the
  window follows the header. The host learns a new display's id from the first packet that
  carries an id it has not seen.

### The host (Mac side)

- **Requests are a queue.** `requestFusionDisplay` appends a `FusionRequest` (package, or nil
  for Desktop Mode) to `pendingFusion` and sends `CreateNewDisplay` — 1920×1080 at 240 dpi,
  `decorations = (package == nil)`. If no session is running yet, the request waits and is sent
  from the `.running` state hook; the session is started *prepared* (not revealed), so the main
  stage does not change.
- **Decode per display.** `VideoStream` reads the single video socket and keeps a pipeline per
  display id: Annex-B splitting, parameter-set tracking, and a `VideoToolbox`
  `VTDecompressionSession` with BGRA output (BGRA so the same frames feed Metal for the 3D twin
  and `AVAssetWriter` for recording without conversion). Packets for an unknown id create a
  pipeline on demand; the primary display's pipeline is the one the Info tab reports.
- **The window opens on the first packet.** `video.onGeometry` fires for every header. An id
  that is neither the phone's (0) nor what the stage shows, while `pendingFusion` is non-empty,
  answers the oldest request: `openFusionWindow(displayId:for:)` creates a `FusionWindow`, wires
  `decoder(for: id).onFrame` to that window's `MirrorView.displayLayer`, and applies the header
  (size, orientation). Later headers for the id go straight to that window.
- **Rendering.** `MirrorView` owns a `VideoLayer` — an `AVSampleBufferDisplayLayer` fed from a
  `CVDisplayLink`: the decode thread only stores the newest picture; the display link enqueues
  it once per refresh, so the layer never sees more frames than it can show. The picture is
  aspect-fit in the window (1152×648 for the 16:9 display), a `sublayerTransform` undoes the
  agent's pre-rotation (`display_orientation_correction`), and `displayRect()` is the exact
  on-screen rectangle of the display — the same rectangle touches are mapped through. A fusion
  display draws no bezel and no rounded corners (`displayId != 0`), because it is a desktop, not
  a phone.
- **The naked window.** `fullSizeContentView` is on in both chrome states; the title bar and
  its accessory (Wake / Screenshot / Record) are painted over the top of the content when the
  pointer nears the top edge. On that toggle the picture is padded down by the title bar's
  height and the frame grows *upward* by the same amount in one pass, so the picture never moves.
  The cursor poll never changes chrome while a mouse button is down (a drag), or for 0.4 s after
  the release.

### Input

- **Touch.** `MirrorView` turns mouse events into `MotionEvent` messages:
  `int32 type=1, uint32 pointer_count, per pointer {int32 x, int32 y, int32 id, uint32
  axis_count, [int32 axis, float value]…}, int32 action, int32 button_state, int32
  action_button, int32 display_id, bool is_mouse`. The coordinates are device pixels in the
  display's *original* orientation — `devicePoint` maps the view point through `displayRect()`
  and the presented rotation (Studio's own quadrant cases) — and `display_id` is the virtual
  display's, which is what routes the event there. Every event carries its pointer, `ACTION_UP`
  included (an empty pointer array makes a malformed event on the agent side). Scroll wheel
  becomes a pointer with `AXIS_VSCROLL`.
- **Keys.** `KeyEvent` messages (`int32 type=2, int32 action, int32 keycode, uint32 meta`)
  and `TextInput` (`int32 type=3, string16` — a UTF-16 count *plus one*, 0 meaning null) carry
  no display id: the agent injects them into the focused window, and `OWN_FOCUS` is what lets
  the virtual display hold focus while the phone's screen shows something else. Clicking a
  fusion window focuses it first.
- **Wake.** The title-bar Wake button sends WAKEUP and `wm dismiss-keyguard` over adb — a real
  PIN is not bypassed; its prompt simply appears.

### Screenshot and recording, in detail

- Screenshot: `screencap -p` needs the *physical* display id for `-d`; the app resolves it with
  `dumpsys SurfaceFlinger --display-id | grep rplayhub.display`, captures to
  `/data/local/tmp/`, and pulls the PNG over `sync:` (not through a shell, which would mangle
  the bytes as UTF-8).
- Recording: `FrameRecorder` appends the decoded BGRA `CVPixelBuffer`s to an `AVAssetWriter`
  (`.mp4`, H.264) through a pixel-buffer adaptor, timestamped on arrival. Android's own
  `screenrecord --display-id` refuses virtual displays; this path has no three-minute cap.

### Requirements and limits

- Standalone virtual displays need **API 34+** (the agent refuses below it); the mirror itself
  needs API 26 for the agent, and Android 5.0–7.1 use the legacy agent, which has no virtual
  displays.
- One live device session at a time; fusion windows belong to it and are discarded on a switch.
- Display size is fixed at 1920×1080 / 240 dpi today (no resize of the virtual display after
  creation).

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
