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
- **`tools/build-agent.sh`** — builds the agent and lays it out where the app looks for it.

## Quick start

```
tools/build-agent.sh          # needs a JDK 17+, the Android SDK and an NDK
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
| Agent deploy → launch → two channels | written, **not yet run against a device** |
| Video: 44-byte header → Annex-B → VideoToolbox | written, **not yet run** |
| Control: base128 MotionEvent / KeyEvent | written, **not yet run** |

Everything up to the device is done and proven. Nothing has touched a real device yet: both the
USB and the network Pixel sit at `unauthorized`, which needs the "Allow USB debugging" dialog
accepted on the device itself. That one tap is the only thing between here and a first frame.

## Toolchain on this machine

`java` from Homebrew or Temurin **cannot run here**. `boot-args` carries
`amfi_get_out_of_my_way=1`, and disabling AMFI breaks the Apple-Silicon JIT write-protect path,
so every arm64 JVM dies with `SIGBUS/BUS_ADRALN` inside `CodeHeap::allocate` before executing a
line of Java. Presumably AMFI is off for the iOS work in `~/rplay-hub`.

The workaround is an **x86_64 JDK under Rosetta**, which handles W^X itself and is unaffected:

```
export JAVA_HOME=~/Library/Java/JavaVirtualMachines/temurin-21-x64/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="$JAVA_HOME/bin:$PATH"
```

Installed: Temurin 21 (x86_64), Android cmdline-tools, platform-tools, platform 36,
build-tools 36.1.0, NDK 29.0.14206865. The NDK's own clang is x86_64 and runs under Rosetta too,
which is why the C++ half builds.

## Not built yet

Audio, clipboard sync, multi-display, XR, foldable device-state, screen recording. The agent
supports all of them; the host never asks.
