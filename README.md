# rplay-hub-android

**`adb` for Android with a GUI** — mirror and control an Android device from macOS, in the shape
of `~/rplay-hub`'s Device Hub clone. A development tool, not a consumer product.

Sibling project: `~/rplay-hub`, the same thing for iPhone. This one is the easier half, and the
reason is worth stating plainly: on iOS we had to reverse-engineer CoreDevice and write both
ends. Here Google's device agent is **Apache 2.0 and published**, so only the host is ours.

## What this is, and is not

It is a from-scratch reimplementation of Android Studio's **Running Devices** window — the
mirroring and control half of it, nothing else. Same on-device agent, same wire protocol, none of
the IDE.

It is **not** a reimplementation of adb. adb is the documented interface, Studio itself goes
through it, and the interesting part of the link is the device end. That is the one place this
project's instincts differ from `~/rplay-hub`, where replacing usbmuxd was the whole point.

## Layout

Folder conventions follow `~/rplay-hub`: adopted sources recorded in `refs/`, tooling in
`tools/`, protocol notes in `doc/`.

- **`app/`** — **rPlayHubAndroid**, the macOS app. Swift + AppKit, an Xcode project. Builds
  clean. See `app/README.md`.
- **`refs/studio/`** — the adopted Apache-2.0 source: the device agent complete, and Studio's
  Kotlin host for reference. See `refs/studio/PROVENANCE.md` for commit and refetch.
- **`doc/STUDIO-MIRRORING-PROTOCOL.md`** — the wire protocol, read out of that source.
- **`doc/PORTING.md`** — the three OS seams, and why the web port is a different shape.
- **`tools/build-agent.sh`** — builds the agent and lays it out where the app looks for it.
- **`tools/gen-xcodeproj.py`** — regenerates the Xcode project from the source files present.

## Quick start

```
tools/build-agent.sh          # needs a JDK 17+, the Android SDK and an NDK (see below)
xcodebuild -project app/rPlayHubAndroid.xcodeproj -scheme rPlayHubAndroid build
open ~/Library/Developer/Xcode/DerivedData/rPlayHubAndroid-*/Build/Products/Debug/rPlayHubAndroid.app
```

Then plug in a device with USB debugging on, accept the prompt, and double-click its row.

## Status

| | |
|---|---|
| Studio source vendored, protocol documented | done |
| macOS app, three panes, device list | builds clean, runs |
| adb host protocol (`devices`, `shell`, `reverse`, sync push) | written, verified against a live adb server |
| Building the agent | **done** — `tools/build-agent.sh`, jar + 4 ABIs |
| Agent deploy → launch → three channels | **verified** |
| Video: 44-byte header → Annex-B → VideoToolbox | **verified** — H.264, hardware decode |
| Control: base128 MotionEvent / KeyEvent | **verified** — keys and touch, against a Pixel 9a |
| Right panel: Info, Apps, Files, Logcat, Crashes, Settings | **working** |
| Right-click menu, open as window/tab, pin | **working** |
| Audio forwarding — device audio on the Mac (Opus 48 kHz) | **working** — on by default, API 31+ |
| Clipboard sync, both directions | **working** — on by default |
| Turn screen off while mirroring | **working** — Device menu |
| Drag-and-drop: APK installs, files land in Download | **working** |
| 3D device twin — gyro-tracked 3D mirror (experimental, gated) | **working** — see below |

Verified end to end against a Pixel 9a (tegu, Android 17 / SDK 37) over network adb.

**Fixed issue (2026-08-30):** long sessions used to die with `kVTVideoDecoderBadDataErr (-12909)`.
Root cause: the agent's `SocketWriter::Write()` can time out with a video packet *half-written*
(partial `write()`, then EAGAIN past the 10s deadline), and upstream's `display_streamer.cc`
ignores the TIMEOUT and writes the next packet right after the truncation — desynchronising the
byte stream, so payload bytes get parsed as headers and eventually reach VideoToolbox as garbage.
Fixed in two layers: our agent build now ends the stream on a video write timeout (see
`refs/studio/PROVENANCE.md`, local modifications), and the host validates every packet header
(geometry bounds, near-sequential frame numbers) and auto-reconnects on desync or mid-stream agent
exit — at most 3 times a minute before surfacing the error. Verified against the Pixel 9a with a
fault-injecting agent build and a read-stall debug hook (`RPLAYHUB_VIDEO_STALL`, see
`VideoStream.swift`).

## The 3D device twin (experimental)

A display mode, not a second viewer: "View in 3D" swaps the flat mirror for a 3D phone whose
orientation tracks the real device's rotation vector sensor live — turn the phone in your hand
and the model turns on screen, with the mirrored display texture-mapped onto its glass. Drag to
orbit the camera. Re-centre (R, or the button) is a calibration: hold the phone parallel to your
Mac's screen and press it — that pose becomes face-on, and every motion after is shown as the
delta from it, heading-corrected so directions stay true (turn left, it turns left; tilt the top
toward you, it comes toward you). `RPLAYHUB_FAKE_GYRO=1` replaces the sensor with scripted poses
(face-on, yaw, pitch, roll) for verifying exactly that without a hand on the phone.

Gated off by default: enable with **View ▸ 3D Device Twin (Experimental)** (persisted), or
`RPLAYHUB_TWIN=1` for one launch. The gate also controls the extra agent channel — our agent
build streams 50 Hz quaternions on a fourth socket only when asked (flag `0x100`; see
`refs/studio/PROVENANCE.md`). While the mode is active the decoder outputs BGRA for the Metal
texture path; the stream is restarted around the switch so it lands on a clean keyframe.

## If your JDK crashes on startup

On Apple Silicon, a machine with AMFI disabled (`boot-args amfi_get_out_of_my_way=1`) cannot run
any arm64 JVM: AMFI mediates the JIT write-protect path, so every JDK — Homebrew, Temurin, 21 or
25 — dies with `SIGBUS`/`BUS_ADRALN` inside `CodeHeap::allocate` before executing a line of Java.
It is not a JDK bug and no version of one fixes it.

People usually turn AMFI off for unrelated reasons (kernel work, unsigned code, iOS research), and
turning it back on means a trip through Recovery. The cheaper way out is an **x86_64 JDK under
Rosetta**, which handles W^X itself and is unaffected:

```
curl -Lo jdk.tar.gz "https://api.adoptium.net/v3/binary/latest/21/ga/mac/x64/jdk/hotspot/normal/eclipse"
mkdir -p ~/Library/Java/JavaVirtualMachines/temurin-21-x64
tar xzf jdk.tar.gz -C ~/Library/Java/JavaVirtualMachines/temurin-21-x64 --strip-components=1
export JAVA_HOME=~/Library/Java/JavaVirtualMachines/temurin-21-x64/Contents/Home
```

`tools/build-agent.sh` picks that JDK up on its own if it is there. The NDK's own clang is x86_64
too, so the C++ half builds under Rosetta without any extra help.

## Upcoming

**Today this is macOS only.** Linux, Windows and a browser client are all planned.

| | |
|---|---|
| **Linux** | `Glibc` sockets, ffmpeg decode, SDL2 or Wayland/EGL |
| **Windows** | Winsock, ffmpeg or Media Foundation / D3D11VA |
| **Web** | headless host + WebSocket, browser decode via WebCodecs |

The protocol layer is already portable — the adb client, the agent launch, the packet header, the
Annex-B splitting and the base128 control codec are Foundation-only and import nothing
platform-specific. What is macOS-bound is sockets (one file), decode and display (VideoToolbox),
and the AppKit shell. `doc/PORTING.md` has the seam-by-seam detail.

The web is not simply a fourth platform. This app deliberately has no engine process, because adb
needs no privilege and collapsing that split was the right call for a desktop app; a browser client
puts it back, with the host headless and the browser decoding H.264 through WebCodecs. That is also
the version that makes several devices and several viewers possible, which the desktop app cannot
express.

Also not built, on any platform: audio, clipboard sync, multi-display, XR, foldable device-state,
screen recording, and bit-rate adaptation. The agent supports all of them; the host never asks.

## License

Our code is MIT — see `LICENSE`.

`refs/studio/` is Google's, Apache 2.0, kept with its own headers and its origin recorded in
`refs/studio/PROVENANCE.md`. Nothing in it is relicensed.
