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
- GCC / G++ (C++17)
- CMake (>= 3.16)
- SDL2 (`libsdl2-dev`)
- FFmpeg development libraries (`libavcodec-dev`, `libavformat-dev`, `libswscale-dev`, `libavutil-dev`)
- Android SDK & NDK (for building the device agent)

*Note: Dear ImGui is fetched automatically at configure time via CMake `FetchContent` (no submodules or manual installation required).*

### 1. Build the Device Agent (Once)
```bash
tools/build-agent.sh
```
This produces `build/agent/screen-sharing-agent.jar` and `<abi>/libscreen-sharing-agent.so`.

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
Or start immediately mirroring the first connected device:
```bash
./linux/build/rplayhub-android-linux --mirror
```
