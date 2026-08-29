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

One, recorded here so a resync can reapply it:

- `screen-sharing-agent/BUILD` → `BUILD.bazel`. macOS is case-insensitive by default, so bazel's
  `BUILD` file occupies the same name as the `build/` directory Gradle wants to create, and the
  build fails at the end with `Could not create ... build/reports/problems`. We build with Gradle
  and never bazel, and `BUILD.bazel` is an equally valid bazel filename, so renaming costs
  nothing. Nothing else in the vendored tree is touched.

## Refetch

    B=refs/heads/mirror-goog-studio-main
    curl -sO "https://android.googlesource.com/platform/tools/adt/idea/+archive/$B/streaming/screen-sharing-agent.tar.gz"
    curl -sO "https://android.googlesource.com/platform/tools/adt/idea/+archive/$B/streaming.tar.gz"

Gitiles `+archive/<ref>/<path>.tar.gz` returns a subtree — no need to clone the
full Studio repo (which is multi-GB).
