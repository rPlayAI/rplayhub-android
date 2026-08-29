# app/ — rPlayHubAndroid, the mirror + control app

A native macOS app: a live screen showing an Android device, where clicks become touches and
drags become drags. Swift and AppKit, an Xcode project. Same three-pane shape as `~/rplay-hub`'s
Device Hub clone, with the iOS engine replaced by Google's screen-sharing agent over adb.

Builds clean today (Debug, no warnings). It has **not yet been run against a device** — that
needs the agent built, which needs an Android SDK and NDK this machine does not have.

## Build and run

```
xcodebuild -project app/rPlayHubAndroid.xcodeproj -scheme rPlayHubAndroid -configuration Debug build
tools/build-agent.sh                                     # once, to produce build/agent/
open app/rPlayHubAndroid.xcodeproj                       # or just work in Xcode
```

No engine to start first. adb needs no privilege, so the app deploys and launches the agent
itself — which is the one structural simplification Android buys us over iOS, where the tunnel
needs root and the privileged half had to live in a separate process.

## Window layout

```
┌────────────────┬───────────────────────┬──────────────┐
│ Search         │                       │ Device       │
│ Available      │    live screen        │  Serial …    │
│ ● Pixel 8      │    click = touch      │  Android 15  │
│ ○ SM-G991B     │    drag  = drag       │  ABI arm64   │
│                │                       │ Stream       │
│                │  ◀ ○ □  🔉 🔊 ⏻ ↻ 📷  │  h264        │
│                │                       │  1080x2400   │
└────────────────┴───────────────────────┴──────────────┘
```

The button strip lives under the picture because it acts on the picture. Android's three
navigation buttons are the ones with no mouse equivalent at all — on a gesture-navigation device
there is nowhere to click for Back — so without them the mirror is only half usable. The title
bar's two tabs switch the right pane between device properties and the agent's log.

## Files

```
app/
  rPlayHubAndroid.xcodeproj/    the Xcode project (target: rPlayHubAndroid, app bundle)
  rPlayHubAndroid/
    main.swift                  NSApplication bootstrap
    AppDelegate.swift           window, panes, device polling, session lifecycle
    DeviceSidebar.swift         the device list, backed by `adb devices -l`
    MirrorView.swift            the screen: crop, rotation, clicks → MotionEvents
    ControlStrip.swift          Back/Home/Overview/volume/power/rotate/screenshot
    InspectorPane.swift         device properties and stream health
    LogcatPanel.swift           the agent's own log
    IconTabBar.swift            title-bar tabs        (verbatim from ~/rplay-hub)
    ScreenWindow.swift          screen in its own window (verbatim from ~/rplay-hub)

    Adb.swift                   the adb server's host protocol, spoken on :5037
    AgentSession.swift          push, reverse, app_process, accept the two channels
    TCPSocket.swift             blocking sockets + the loopback listener
    Base128.swift               the control channel's varint codec
    ControlMessages.swift       host → agent messages, and the Android constants
    VideoPacket.swift           the 44-byte per-frame header
    VideoStream.swift           video channel → access units → decoder
    AnnexB.swift                start-code splitting, per-codec NAL rules
    VideoDecoder.swift          VideoToolbox, and the display-link layer
```

## How it works

```
AgentSession ──adb push──▶ /data/local/tmp/.studio
             ──adb reverse localabstract:screen-sharing-agent-<port> ─▶ tcp:<port>
             ──adb shell app_process …──▶ agent (shell uid)
    'V' ◀── 44-byte header + Annex-B ──── MediaCodec
    'C' ──── base128 MotionEvent/KeyEvent ──▶ InputManager.injectInputEvent
```

Protocol details, and where each field was read from, are in `doc/STUDIO-MIRRORING-PROTOCOL.md`.

### Decoding: VideoToolbox, hardware, no ffmpeg

Same choice as `~/rplay-hub`, and the code is adopted from it: the app links only AppKit,
AVFoundation and CoreMedia. Studio decodes with a bundled ffmpeg; we do not need it, because
VideoToolbox handles both codecs the agent will give us.

Decode and display stay separate stages, which is the part worth keeping. Feeding compressed
samples to `AVSampleBufferDisplayLayer` lets it drop them **before** decoding, which breaks the
reference chain until the next keyframe. Here every access unit is decoded, in order; only
finished pictures are ever skipped, and a display link presents the newest one per refresh.

What was dropped from the iOS version: the RVRA machinery, the coded-resolution trailer parser,
and the first-slice access-unit heuristic. None have an analogue here — the agent frames each
packet as one complete access unit and signals resolution changes with fresh parameter sets.

### Three things that differ from the iOS path

- **The padding is centred, not top-left.** `ComputeVideoSize` rounds the encode width up to a
  multiple of 8 and the height to a multiple of 2, then letterboxes the display inside it with
  equal strips top and bottom. Cropping to the top-left corner — correct on iOS — would show one
  strip here and shift every touch by half the other.
- **Raw motion events, not gestures.** The iOS engine takes `tap`/`swipe`; this one takes
  ACTION_DOWN/MOVE/UP at the device's own coordinates, so the device's gesture detector decides
  what they mean. Flings and long-presses work without any of it being modelled here.
- **Coordinates go in the display's ORIGINAL orientation.** The rotation cases in
  `MirrorView.devicePoint` are Studio's own (`AbstractDisplayView.toDeviceDisplayCoordinates`),
  reduced to fractions. Getting this wrong is the worst kind of broken: the tap still lands, just
  somewhere else.

## Not built yet

Audio, clipboard sync, multi-display, XR, foldable device-state, screen recording, and the
`--turn-off-display` path. The agent supports all of them; the host simply never asks.

Distribution follows `~/rplay-hub/app/DISTRIBUTION.md`: Developer ID and notarization, not the
App Store. Here the blocker is the loopback listener the agent dials back into — a sandboxed app
has the network-server entitlement but cannot be relied on for this, and there is no adb
entitlement at all.
