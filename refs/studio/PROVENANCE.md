# Provenance — Android Studio device mirroring

Adopted from AOSP, Apache License 2.0.

- Repo: https://android.googlesource.com/platform/tools/adt/idea
- Branch: `mirror-goog-studio-main`
- Commit: `04ca1eeab5ca7cb131322dbb65364bd11508d0fa`
- Retrieved: 2026-08-29

## What was taken

| Path here | Upstream path | What it is |
|---|---|---|
| `screen-sharing-agent/` | `streaming/screen-sharing-agent/` | The **device-side agent**, complete. C++20 + a thin Java launcher. ~15k LOC. |
| `streaming-host/device/` | `streaming/src/com/android/tools/idea/streaming/device/` | The **host side**, Kotlin. What we are reimplementing in C. |
| `streaming-host/native/` | `streaming/native/` | `ImageConverter.c` — host-side C, ffmpeg frame → ARGB. Prebuilt `.dylib`/`.dll`/`.so` omitted. |

Omitted: `.idea/`, the emulator/XR/benchmarker siblings, tests.

## Local modifications

Recorded here so a resync can reapply them:

- `screen-sharing-agent/BUILD` → `BUILD.bazel`. macOS is case-insensitive by default, so bazel's
  `BUILD` file occupies the same name as the `build/` directory Gradle wants to create, and the
  build fails at the end with `Could not create ... build/reports/problems`. We build with Gradle
  and never bazel, and `BUILD.bazel` is an equally valid bazel filename, so renaming costs
  nothing.

- `screen-sharing-agent/app/src/main/cpp/display_streamer.cc`: treat `SocketWriter::Result::TIMEOUT`
  from a video packet write as end of stream, at both write sites (the frame loop and the
  empty-frame-on-timeout path). Upstream ignores TIMEOUT and keeps streaming, but
  `SocketWriter::Write()` can time out with a packet *half-written* (a partial `write()` followed
  by EAGAIN past the 10s deadline) and does not track how much was sent — every byte written
  afterwards is misframed, and the host's decoder eventually dies with
  `kVTVideoDecoderBadDataErr (-12909)`. Ending the stream lets the host reconnect cleanly.
  Candidate for upstreaming.

- **Sensor channel (new capability, ours):** `sensor_streamer.{h,cc}` (new files), plus hooks in
  `flags.h` (`STREAM_ORIENTATION = 0x100`, kept away from upstream's bits), `agent.{h,cc}`
  (fourth socket, channel marker `'S'`, streamer lifecycle in `Run`/`Shutdown`), and
  `CMakeLists.txt`. When the flag is set the agent opens a fourth socket and streams the
  rotation vector quaternion (NDK ASensor API — no Context needed under app_process) at 50 Hz,
  24 bytes per packet: four little-endian float32 (x, y, z, w) + int64 timestamp_ns. Drives the
  host's 3D "device twin" view. Not upstreamable as-is; on a resync, re-add the files and hooks.

## Refetch

    B=refs/heads/mirror-goog-studio-main
    curl -sO "https://android.googlesource.com/platform/tools/adt/idea/+archive/$B/streaming/screen-sharing-agent.tar.gz"
    curl -sO "https://android.googlesource.com/platform/tools/adt/idea/+archive/$B/streaming.tar.gz"

Gitiles `+archive/<ref>/<path>.tar.gz` returns a subtree — no need to clone the
full Studio repo (which is multi-GB).
