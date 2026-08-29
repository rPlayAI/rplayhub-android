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
| Agent deploy → launch → two channels | written, **not yet run against a device** |
| Video: 44-byte header → Annex-B → VideoToolbox | written, **not yet run** |
| Control: base128 MotionEvent / KeyEvent | written, **not yet run** |

Everything up to the device is done and proven. Nothing has touched a real device yet: both the
USB and the network Pixel sit at `unauthorized`, which needs the "Allow USB debugging" dialog
accepted on the device itself. That one tap is the only thing between here and a first frame.

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

## Not built yet

Audio, clipboard sync, multi-display, XR, foldable device-state, screen recording. The agent
supports all of them; the host never asks.

## License

Our code is MIT — see `LICENSE`.

`refs/studio/` is Google's, Apache 2.0, kept with its own headers and its origin recorded in
`refs/studio/PROVENANCE.md`. Nothing in it is relicensed.
