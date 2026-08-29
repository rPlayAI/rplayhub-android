# Android Studio device mirroring — wire protocol

What the host must do to get pixels off a device. Everything below is read out of
`refs/studio/` (see `refs/studio/PROVENANCE.md`), not guessed.

Host-side reference: `refs/studio/streaming-host/device/DeviceClient.kt`.
Device-side reference: `refs/studio/screen-sharing-agent/app/src/main/cpp/`.

## 0. Shape

Unlike iOS/CoreDevice there is nothing to reverse — the agent is Apache 2.0 and we
build it as-is. Only the **host** is ours. That inverts the rplay-hub effort:
the protocol is known, the work is the C host and the render/input loop.

    host (ours, C)                          device
    ---------------                         ------
    adb push agent ------------------------> /data/local/tmp/.studio/
    adb reverse localabstract:… -> tcp:PORT
    adb shell app_process … ---------------> agent starts
                        <---- 3 sockets ---- V / A / C
    ffmpeg decode  <----- H.264 Annex-B ---- MediaCodec
    input events ------- base128 msgs -----> InputManager.injectInputEvent

## 1. Deploy

Two artifacts, pushed to `DEVICE_PATH_BASE = /data/local/tmp/.studio`:

- `screen-sharing-agent.jar`
- `libscreen-sharing-agent.so` (per-ABI)

Studio `chown shell:shell`s the directory, because if adb is rooted the push lands
as root and the agent then can't be launched as shell.

## 2. Reverse forward

Host opens a **TCP listener on loopback, port 0** (kernel picks `PORT`), then:

    adb reverse localabstract:screen-sharing-agent-<PORT>  tcp:<PORT>

The abstract socket name embeds the port purely to keep concurrent sessions from
colliding. Once the agent's sockets are connected the reverse can be removed —
established connections survive it.

## 3. Launch

    CLASSPATH=/data/local/tmp/.studio/screen-sharing-agent.jar \
      app_process /data/local/tmp/.studio \
      com.android.tools.screensharing.Main \
      --socket=screen-sharing-agent-<PORT> \
      [--max_size=W,H] [--orientation=N] [--flags=N] \
      [--max_bit_rate=N] [--log_level=…] [--codec=…]

`app_process` is the trick: the agent runs as **shell UID**, which is what grants
`INJECT_EVENTS` and access to hidden system services. No root, no install.

`Main.java` loads the `.so` and jumps straight to native `agent.cc`; the Java side
is a launcher and a few callback shims (rotation watcher, clipboard, display
listener) that need a JVM-side interface.

## 4. Channels

The agent dials **back** through the reverse tunnel and opens up to three
connections to our listener. Each begins with a **one-byte marker** identifying
itself — accept, read one byte, then assign:

| Marker | Channel |
|---|---|
| `'V'` (0x56) | video |
| `'A'` (0x41) | audio — only if device API ≥ 31 |
| `'C'` (0x43) | control |

Order is not guaranteed; Studio accepts all N in parallel and sorts by marker.
Control channel gets `TCP_NODELAY`.

Only 2 channels are expected unless audio streaming is supported. For viewer +
control we ask for 2 and skip audio entirely.

## 5. Video channel

After the marker, once:

- **20-byte channel header** (`CHANNEL_HEADER_LENGTH`) — the codec name as ASCII,
  space padded. Trim it. Accepted values and their ffmpeg decoder names:

  | On the wire | ffmpeg |
  |---|---|
  | `avc`, `h264` | `h264` |
  | `hevc` | `hevc` |
  | `av01` | `av1` |
  | `vp8` / `vp9` | `vp8` / `vp9` |
  | `vvc` | `vvc` |

Then repeating, forever:

- **44-byte packet header**, little-endian, layout from
  `cpp/video_packet_header.h` (note: 44 is the packed size, *not*
  `sizeof(VideoPacketHeader)` — there is trailing alignment to ignore):

      int32  display_id
      int32  display_width
      int32  display_height
      uint8  display_orientation             // quadrants
      uint8  display_orientation_correction  // quadrants
      int16  flags                           // 0x01 round, 0x02 bitrate reduced, 0x04 camera
      int32  bit_rate
      uint32 frame_number                    // starts at 1
      int64  origination_timestamp_us
      int64  presentation_timestamp_us       // 0 => config packet (SPS/PPS)
      int32  packet_size

- **`packet_size` bytes** of Annex-B elementary stream.

`presentation_timestamp_us == 0` marks a **config packet** — codec-specific
parameter sets, feed it to the decoder but don't expect a frame.

Studio decodes with ffmpeg via javacpp and `PARSER_FLAG_COMPLETE_FRAMES` (packets
are already whole access units, so no parser re-assembly needed). `core/` in
rplay-hub already does Annex-B parsing, AU assembly and keyframe gating for the
iOS path — **that is the piece that transfers directly.**

Display geometry arrives in *every* packet header, so rotation and resize need no
side channel: the renderer just reacts to the header changing.

## 6. Control channel

Binary, base128 varint framed. Both directions.

- Wire codec: `cpp/base128_input_stream.cc` / `base128_output_stream.cc`
- Messages: `cpp/control_messages.h` ↔ `streaming-host/device/ControlMessages.kt`

The C++ side already exists and is symmetric — for a native host we can lift
`base128_*_stream.*` verbatim and write the mirror-image serializers, rather than
porting `ControlMessages.kt` (which is itself a port of the C++).

## 7. What we skip

Audio, clipboard sync, XR/head-pose, device-state/folding, UI settings, camera.
The agent supports them all; the host simply never opens the audio channel and
never sends those control messages.

## Open / not yet traced

- Exact `--flags` bit meanings.
- Agent exit codes → `streaming-host/device/AgentExitCodes.kt`.
- Bit-rate adaptation loop → `BitRateManager.kt`.
- Whether `vvc` is reachable in practice or aspirational.
