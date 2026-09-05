# rPlayHub Android — Linux GUI

A high-performance, lightweight Linux GUI for **rPlayHub Android**, faithfully reproducing the macOS AppKit/SwiftUI 3-pane layout, design, and interactions without heavyweight frameworks.

Built with **C++17**, **SDL2**, **FFmpeg (libavcodec / libswscale)**, and **Dear ImGui**.

---

## Evaluation of GUI Frameworks

When designing the Linux client to match the macOS UI (see the macOS screenshot):

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Qt / PySide** | Mature desktop widgets | Heavy (>200 MB dependencies), slow cold startup, bloated runtime, MOC build overhead. User explicitly requested: *"don't use bloating gui library like Qt"*. | **Rejected** |
| **GTK4 / Libadwaita** | GNOME-native styling | High dependency footprint (`libgtk-4-dev`, `libadwaita-1-dev` not installed on many headless/custom setups; sudo required). Video pipeline integration (`GtkGLArea`) has higher latency and complex sync across X11/Wayland. Linux-only. | **Not Selected** |
| **Slint (C++)** | Declarative modern UI | Younger ecosystem, compiler toolchain not installed on machine, custom low-latency video streaming backbuffer adapter required. | **Not Selected** |
| **Dear ImGui + SDL2 + FFmpeg** | **Zero bloat**: compiles into a single, compact (~17 MB) self-contained binary. Starts in milliseconds. Matches user's prior architecture (`acast-dev`). Native low-latency hardware/software H.264 decoding via FFmpeg to `SDL_Texture`. Custom styling faithfully reproduces 100% of the macOS UI layout (sidebar, stage, inspector, phone bezel, control strip, pill tabs). | **Selected & Implemented** |

---

## Features

- **3-Pane macOS-Style Interface**:
  - **Left Sidebar**:
    - macOS traffic lights window controls.
    - Pill-shaped device search bar.
    - Available devices card list with live status indicators (green dot for ready, yellow for unauthorized, red for offline).
    - Device display name and serial/network address.
    - Complete right-click context menu (Start/Stop Mirroring, Desktop Mode, Copy Serial, Disconnect, Screenshot, Record, Back, Home, Recents, Rotate, Wake, Power, Reconnect).
    - `+` modal to connect to network adb (`ip:port`).
    - Device refresh and live bottom status line (`adb server 5037 - N devices`).
  - **Center Stage**:
    - Device title and OS status header (`Pixel 8a - Android 17 - Mirroring active`).
    - Realistic phone chassis with rounded black bezel surround and front punch-hole camera cutout.
    - Ultra-low latency H.264 video decoding (Annex-B stream directly to FFmpeg `libavcodec` -> `swscale` -> `SDL_Texture`).
    - Sub-pixel mouse touch mapping: click = touch down, drag = swipe, release = touch up, wheel = scroll.
    - Right-click acts as Android Back button.
    - Keyboard input forwarding (Enter, Backspace, Tab, Escape, and text input).
    - Bottom navigation control strip (`<` Back, `O` Home, `[]` Recents, `Vol -`, `Vol +`, `Power`, `Rotate`, `Camera` Screenshot, `Record`).
  - **Right Inspector Pane**:
    - Pill segmented control tabs: **Info**, **Apps**, **Files**, and **Logcat**.
    - **Apps Tab**:
      - Scrollable list of installed apps formatted as `AppName (com.package.name)`.
      - Double-click to launch app via `monkey`.
      - Right-click popup: Launch, Force Stop, Uninstall.
      - Package count label, `System apps` filter toggle, and search filter input box.
    - **Info Tab**:
      - Device properties (Model, Manufacturer, Android Version, SDK API Level, CPU ABI, Serial, Battery %).
    - **Files Tab**:
      - Explore `/sdcard/Download`, refresh, view remote directory contents.
    - **Logcat Tab**:
      - Live log streaming from the on-device screen-sharing agent.

---

## Build & Run

*Continuing this port on a Linux host or a Raspberry Pi? See [`doc/LINUX-AND-RPI.md`](../doc/LINUX-AND-RPI.md).*

### Prerequisites
- GCC / G++ (C++17) and CMake (>= 3.16)
- SDL2 and FFmpeg development libraries, adb, pkg-config

Debian / Ubuntu / Raspberry Pi OS (Bookworm or later; verified on Ubuntu 22.04 x86_64):
```bash
sudo apt install build-essential cmake pkg-config git \
     libsdl2-dev libavcodec-dev libavformat-dev libswscale-dev libavutil-dev adb
```
The adb package is `android-tools-adb` on older releases. Add yourself to `plugdev` if adb cannot see a USB phone.

Dear ImGui is fetched automatically at configure time via CMake `FetchContent` (network needed once).

If a second FFmpeg or SDL2 lives in `/usr/local` (a self-built one next to the distro's), pkg-config
picks it and the build links against that copy — check with `ldd linux/build/rplayhub-android-linux`.

### 1. Build the Device Agent (Once)
```bash
tools/build-agent.sh
```
This needs the Android SDK + NDK and an x86_64 or macOS host (Google ships no Linux arm64
build-tools), and produces `build/agent/screen-sharing-agent.jar` and
`<abi>/libscreen-sharing-agent.so`. The output is device-side and architecture-independent, so on
a machine that cannot build it (a Raspberry Pi) copy `build/agent/` over or point
`RPLAYHUB_AGENT_DIR` at a copy. The client looks in `build/agent`, `../build/agent`,
`../../build/agent` relative to the working directory, then `$RPLAYHUB_AGENT_DIR`.

### 2. Build the Linux GUI
```bash
cd linux
mkdir -p build && cd build
cmake ..
make -j$(nproc)
```

### 3. Run
```bash
./linux/build/rplayhub-android-linux
```
Or start immediately mirroring the first ready device:
```bash
./linux/build/rplayhub-android-linux --mirror
```

Options:

| Flag | Environment | Meaning |
|---|---|---|
| `-m`, `--mirror` | | Start mirroring immediately |
| `--serial <s>` | `RPLAYHUB_SERIAL` | Device `--mirror` picks (a USB serial or `ip:port`); default is the first ready device |
| `-s`, `--scale <f>` | `RPLAYHUB_SCALE` | UI scale factor (auto-detected from the display size) |
| `--dump-frame <path>` | | Save a BMP of the window once the mirror is showing video, then keep running |
| `--stats` | | Print decoded / rendered frames per second to stderr every 5 s |
| | `RPLAYHUB_AGENT_DIR` | Directory holding the device agent (see above) |

Run from the repository root so the agent and `linux/fonts/` are found (Roboto is the fallback).
