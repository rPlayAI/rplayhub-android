# Porting — macOS now, Linux, Windows and the web next

We will run beyond macOS, so the work is to keep every OS dependency behind a named seam and
implement that seam per platform. Everything else — the adb host protocol, the agent launch
sequence, the packet header, the Annex-B splitting, the base128 control codec — is portable and
should never learn which OS it is on.

The good news is how little is not portable. This project has **three** seams where
`~/rplay-hub` has four, and the hard one there (creating a `utun`, privileged, no native Windows
equivalent) has no counterpart here at all: adb needs no privilege on any platform.

## What is already portable

Foundation only, no platform API, nothing to do:

| file | what it is |
|---|---|
| `Adb.swift` | the adb server's host protocol, including sync push |
| `AgentSession.swift` | push → reverse → `app_process` → accept the channels |
| `Base128.swift` | the control channel's varint codec |
| `ControlMessages.swift` | host → agent input messages |
| `AnnexB.swift` | start-code splitting and the per-codec NAL rules |
| `VideoPacket.swift` | the 44-byte header |
| `DisplayShape.swift` | the device silhouette, parsed out of `dumpsys` |

That is the whole protocol. The one wrinkle is that `VideoPacket` and `DisplayShape` use
`CGSize`/`CGPoint`/`CGRect`, and CoreGraphics does not exist on Linux — a dozen-line shim, not a
seam.

## The three seams

### 1. Sockets — trivial

`TCPSocket.swift` is the only file that imports `Darwin`. It is plain BSD sockets plus a
loopback listener.

| platform | mechanism | state |
|---|---|---|
| macOS | `Darwin`, `AF_INET`, `select` | working |
| Linux | `Glibc`, identical calls | not started, near-mechanical |
| Windows | Winsock 2 — `WSAStartup`, `SOCKET` not `Int32`, `closesocket`, no `SO_RCVTIMEO` semantics match | not started |

The `fd_set` handling is already written out by hand because Swift cannot see the C macros, so
Linux needs almost nothing. Windows is the real work, and small.

### 2. Video decode and display — the seam that matters

| platform | decode | display | state |
|---|---|---|---|
| macOS | **VideoToolbox** (hardware) | `AVSampleBufferDisplayLayer` driven by a display link | working |
| Linux | ffmpeg `libavcodec`, VA-API where available | SDL2, or Wayland/EGL | not started |
| Windows | ffmpeg, or Media Foundation / D3D11VA | D3D11 swapchain or SDL2 | not started |

**macOS links no ffmpeg at all**, and that is deliberate — the same call `~/rplay-hub` makes.
Note that Android Studio itself decodes with a bundled ffmpeg on every platform, so ffmpeg is the
known-good path for the other two rather than an experiment.

The refactor this needs is real but contained. `VideoStream.swift` currently does two jobs: it
reads the wire (portable) and it builds `CMSampleBuffer`s (not). Splitting it so the reader emits
access units, and a platform decoder consumes them, is the whole seam. `~/rplay-hub/core/hwdecoder.h`
is exactly that interface already, and it hands back frames rather than sample buffers — which is
why `VideoDecoder.swift` keeps decode and display as separate stages even though macOS would let
you merge them.

### 3. The GUI

`AppKit` in eight files: `AppDelegate`, `MirrorView`, `DeviceSidebar`, `ControlStrip`,
`InspectorPane`, `LogcatPanel`, `IconTabBar`, `ScreenWindow`. Nothing clever, but nothing shared
either. Options are the usual: a Swift GUI toolkit per platform, or rewrite the shell in something
cross-platform and keep the protocol layer as a library.

## The web is a different shape, and worth saying why

Linux and Windows are the same program with three seams filled in. The web is not.

This app deliberately has **no engine process**. `~/rplay-hub` splits engine from GUI because the
iOS tunnel needs root and the privileged half had to live outside a notarized app; adb needs no
privilege, so collapsing that split was the right simplification here.

A browser client puts it back. The host becomes a headless server that owns the adb connection and
the agent session, and the browser gets the frames over a WebSocket. Concretely:

- **decode**: WebCodecs `VideoDecoder` takes H.264 Annex-B directly, so the browser does the job
  VideoToolbox does today and no server-side transcode is needed
- **transport**: the agent's framing already suits this — every packet is one complete access unit
  with its geometry in the header, so it can be forwarded almost verbatim
- **input**: the base128 control messages are small and would go back over the same socket
- **prior art**: `ws-scrcpy` is this exact shape against scrcpy's protocol

So the web port is mostly *unbundling* rather than rewriting, and the protocol layer listed above
is what survives intact. It is also the version that makes several devices and several viewers
possible, which the desktop app cannot express at all.

## Order this should probably happen in

1. Split `VideoStream` at the access-unit boundary — pays off for all three targets and is the
   only change that touches working code.
2. Linux: `Glibc` sockets, ffmpeg decode, SDL2. Proves the seams are real seams.
3. Web: headless host plus a WebSocket, browser client with WebCodecs.
4. Windows: Winsock, and whichever display path SDL2 has not already solved.
