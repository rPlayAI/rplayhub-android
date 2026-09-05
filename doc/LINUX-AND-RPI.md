# Linux host and Raspberry Pi — continuation plan (2026-09-04)

This is the handoff for continuing the Linux client on a Linux host and then taking it to a
Raspberry Pi. It was written on the Mac; nothing below has been built on Linux yet beyond what
`linux/README.md` already documents. Read `linux/README.md` first for the architecture and the
feature list, then this file for what to do next.

## Where things stand

`linux/` is a self-contained C++17 client: SDL2 + FFmpeg + Dear ImGui, ~3.9k lines, landed as
c68909b and verified mirroring a Pixel 8a with touch, keys, Apps / Files / Info / Logcat panes.
It reimplements the agent protocol (`linux/src/protocol`, `linux/src/net`, `linux/src/adb`) and
does **not** share the Swift core, so any protocol change must be made in both places.

There is no architecture-specific code anywhere in `linux/src`. Dependencies are found through
pkg-config; Dear ImGui is fetched by CMake at configure time (needs network once).

What is portable but slow today (this is the whole Pi problem):

- `linux/src/video/video_decoder.cc` picks the generic decoder with `avcodec_find_decoder(id)`
  (line ~46), so H.264 is decoded on the CPU.
- After every decoded frame it runs `sws_scale` YUV → RGBA into `DecodedFrame::rgba`
  (line ~133), and `GuiApp::renderLiveMirror` (`linux/src/ui/gui_app.cc` ~743) uploads that as an
  `SDL_PIXELFORMAT_RGBA32` streaming texture. That is a full-frame colour conversion on the CPU
  plus a 4 byte/pixel upload, per frame.
- The agent is launched with a hard-coded `--codec=avc` and `--max_size=1080,2400`
  (`agent_session.cc` ~172, `gui_app.cc` ~232). No CLI or env override yet.

Not in the Linux client at all (not Pi-specific, listed so nobody looks for them): audio playback
(the audio channel is accepted and parked), the 3D device twin, Finder mount, emulator host, AOA
HID. Google ships no Linux arm64 emulator, so the emulator host can never run on a Pi.

## Step 0 — build on the Linux host

Debian / Ubuntu / Raspberry Pi OS (Bookworm or later):

```bash
sudo apt install build-essential cmake pkg-config git \
     libsdl2-dev libavcodec-dev libavformat-dev libswscale-dev libavutil-dev adb
```

(`adb` is the package name on current Debian/Ubuntu/Raspberry Pi OS; older releases call it
`android-tools-adb`.) Add yourself to `plugdev` if adb cannot see the phone.

The device agent is built by `tools/build-agent.sh`, which needs the Android SDK + NDK. **Build it
on the x86_64 host or the Mac, not on the Pi**: Google does not ship Linux arm64 build-tools
(`aapt2` etc. are x86_64-only). The output is device-side and architecture-independent (a jar
plus one `.so` per Android ABI), so just copy `build/agent/` to the Pi. The client looks in
`build/agent`, `../build/agent`, `../../build/agent` relative to the cwd, or `$RPLAYHUB_AGENT_DIR`.
Alternatively unzip `agent/` out of a release DMG's app bundle.

```bash
cd linux && mkdir -p build && cd build && cmake .. && make -j$(nproc)
cd ../..
./linux/build/rplayhub-android-linux --mirror      # mirrors the first device
```

Other flags today: `--dump <path>` (screenshot), `--scale <f>` / `RPLAYHUB_SCALE` (UI scale).
Fonts: `linux/fonts/Inter-*.ttf` are looked up relative to cwd with a Roboto fallback.

Fix whatever the README got wrong for the distro, then commit that before touching code.

## Step 1 — upload YUV, drop swscale (do this on the host, helps every Linux machine)

Goal: the decoder hands SDL the planes it already has; the GPU does the colour conversion.

- `DecodedFrame`: replace `std::vector<uint8_t> rgba` with three plane buffers and their pitches
  (`y, u, v`, `pitch_y, pitch_uv`) plus an `AVPixelFormat`-ish tag. Keep the copy into
  `latest_frame_` under the existing mutex; the decoder thread owns `av_frame_`.
- `VideoDecoder::decode`: for `AV_PIX_FMT_YUV420P` / `YUVJ420P` copy the three planes
  (`av_image_copy_plane` or a per-row memcpy; note `linesize` may exceed width). For
  `AV_PIX_FMT_NV12` copy Y and the interleaved UV plane. Anything else: keep the current
  `sws_scale` path as the fallback so nothing regresses.
- `GuiApp::renderLiveMirror`: create the texture as `SDL_PIXELFORMAT_IYUV` (or `NV12`) and
  update with `SDL_UpdateYUVTexture(tex, nullptr, Y, pitchY, U, pitchU, V, pitchV)` /
  `SDL_UpdateNVTexture`. The rest of the draw (aspect fit, rotation, bezel) is untouched.
- The `--dump` screenshot path reads back the rendered window, not the frame, so it keeps working.

Verify: `top` CPU for the client at 1080p before/after, and that the picture is not colour-shifted
(check a known red/blue UI element). Commit as its own change.

## Step 2 — make decoder and codec selectable (host, no Pi needed)

Add, in `main.cc` → `GuiApp` → `AgentSession`:

- `--decoder <ffmpeg name>` and `RPLAYHUB_DECODER`: when set, use
  `avcodec_find_decoder_by_name()` instead of `avcodec_find_decoder(id)`, fall back to the
  generic one with a log line if it is missing.
- `--codec avc|hevc` (default `avc`), passed straight through as the agent's `--codec=`. The
  Studio agent supports `avc`, `hevc`, `vp8`, `vp9`, `av1`; `video_decoder.cc` already maps the
  codec name the agent echoes in the 20-byte channel header, so nothing else changes.
- `--max-size WxH` (default `1080x2400`) → `AgentSession::start(max_w, max_h)`.

Sanity check on the host with `--decoder h264` (explicit generic) and, if the host has a GPU,
`--decoder h264_vaapi` is optional but not required for the Pi.

## Step 3 — Raspberry Pi 4 (H.264 in hardware)

Pi 4 has a V4L2 memory-to-memory H.264 decoder that upstream FFmpeg exposes as `h264_v4l2m2m`.
Its default output is plain `yuv420p` copied out of the capture buffers, so after Step 1 it should
"just work":

```bash
./linux/build/rplayhub-android-linux --mirror --decoder h264_v4l2m2m
```

Checks and traps:

- `ls /dev/video1*` must show the decoder nodes (`/dev/video10`…); the user must be in the
  `video` group. `ffmpeg -decoders | grep v4l2m2m` confirms the build has it.
- Bookworm uses the KMS driver (`dtoverlay=vc4-kms-v3d`) by default; SDL's accelerated renderer
  works under both X11 and Wayland/labwc. If `SDL_CreateRenderer` falls back to software
  (`gui_app.cc` ~77 logs it), fix the GL setup before measuring anything.
- If the hardware decoder rejects the stream, the usual cause is the agent's SPS/PPS not being
  sent before the first IDR after a reconfigure; log the first packets and compare with the
  generic decoder.
- Measure at 720p and 1080p (`--max-size 720x1600` vs `1080x2400`) and pick the default cap for
  the Pi. Expect 1080p to be fine in hardware and marginal in software on the A72.

## Step 4 — Raspberry Pi 5 (no H.264 hardware; use HEVC)

Pi 5 has **no** H.264 decoder. It has a 4K HEVC decoder driven through the V4L2 request API,
which only Raspberry Pi's patched FFmpeg (what Raspberry Pi OS ships) knows about — a stock
Ubuntu arm64 image will not have it. Plan:

1. Launch the agent with `--codec hevc` (phones from roughly 2017 on have a hardware HEVC
   encoder; the agent reports the codec name in the channel header, check the log line
   `Agent video codec:`).
2. Find how the installed FFmpeg exposes the decoder: `ffmpeg -hwaccels` and
   `ffmpeg -decoders | grep -i hevc`. On Raspberry Pi OS it has been the standard `hevc` decoder
   with the `drm` hwaccel (`ffmpeg -hwaccel drm -i x.hevc …`), in some builds a separate
   `hevc_v4l2request` decoder. Verify on the board; do not trust this paragraph.
3. If it is a hwaccel rather than a named decoder, set `codec_ctx_->hw_device_ctx` from
   `av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_DRM, "/dev/dri/card0", …)` and pass
   `AV_PIX_FMT_DRM_PRIME` via `get_format`. Frames come back as DRM_PRIME; the cheap first
   version is `av_hwframe_transfer_data()` to a software `yuv420p`/`nv12` frame and then the
   Step 1 upload. Zero-copy DMA-BUF import into SDL is a later optimisation.
4. Fallback that always works: software H.264 with `--max-size 720x1600`. The A76 handles 720p
   in software comfortably and 1080p at reduced frame rate.

## Step 5 (optional) — kiosk

Boot straight into the mirror without a desktop: `SDL_VIDEODRIVER=kmsdrm`, a systemd unit that
runs the client with `--mirror` as the `pi` user, `adb` started as a service so the phone is
already authorised. Check the ImGui SDL2 backend handles the absence of a window manager
(fullscreen desktop mode).

## Working notes for the next session

- Run Claude Code **on the Pi over ssh** for Steps 3–5; the V4L2 decoders can only be tested on
  the board and cross-compiling buys nothing.
- Keep a phone plugged in wherever the build runs — every step is verified against a live mirror.
- The repo is public. Do not commit hostnames, serials, IPs or home paths in logs or docs
  (see the note in `doc/HANDOFF.md`).
- Commit each step separately; Step 1 and Step 2 are independent of the Pi and should land first.
