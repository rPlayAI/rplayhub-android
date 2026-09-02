# Hosting the Android Emulator (Android Studio's model)

Status as of 2026-09-01: **working end to end, experimental, gated.** An emulator selected in the
sidebar is *hosted* — its display streamed and its input injected over the emulator's own gRPC
(`EmulatorController`) — instead of being mirrored like a device over adb + the screen-sharing
agent. No virtual display, no on-device agent, no Qt window. The same instance stays fully
reachable over adb, so every tool (and the app's own screenshot/record/APK/file features) keeps
working against it unchanged.

Read `doc/HANDOFF.md` for the app in general; this file is only the emulator track.

## Why this design

- This is exactly how Android Studio's embedded emulator works: it launches the engine headless
  (`-no-window -grpc`) and talks `EmulatorController` — `streamScreenshot`, `sendTouch`,
  `sendKey`, `setPhysicalModel`. We copy that, not the Qt front end.
- Google's shipped binaries are used as-is (`$SDK/emulator`, never bundled: the SDK license §3.4
  forbids redistributing the prebuilt emulator). The Qt front end (`lib64/qt`, 455 MB) is never
  loaded in this mode.
- An earlier spike tried to host `libgfxstream_backend.dylib` directly with a SwiftUI GL host;
  it needs the engine's globals initialised (emuglConfig_init crashes in a bare host), so a
  Qt-stripped engine is a from-source build (the user's Linux AOSP tree). That track is parked —
  see "Not started".

## Pieces

| Piece | Where | Role |
|---|---|---|
| `EmulatorTransport` | `emulator-transport/` (SwiftPM, NOT part of the app build) | grpc-swift v2 client; pre-generated protobuf/gRPC stubs in `Sources/EmulatorTransport/Generated` (the SPM protoc plugin can't find brew protoc — don't re-add it). `EmulatorTransport.swift` = connect/screenshot/stream/status/tap/key; `Input.swift` = touch/typeText/pressKey/rotate. |
| `emulator-bridge` | same package, executable | Spawned by the app per hosted session. gRPC ↔ stdio so **grpc-swift never links into the app**. stdout: `[4-byte BE length][PNG]` frames. stdin: JSON lines (`touch`, `tap`, `press`, `text`, `rotate`, `key`, `quit` — documented at the top of `Sources/emulator-bridge/main.swift`). |
| `EmulatorSession` | `app/rPlayHubAndroid/EmulatorSession.swift` | App side. Discovers the gRPC port, spawns the bridge, parses frames, decodes PNG → BGRA `CVPixelBuffer` on its own queue, exposes `onFrame`/`onExit`; input helpers (`sendTouch`, `press`, `type`, `rotate`, `perform(ControlStrip.Action)`) and the AndroidKey → DOM-key map. |
| `MirrorView` | `present(picture:size:)`, `var emulator` | The frame is its own geometry (videoSize = displaySize = frame pixels; rotation shows up as a landscape frame). Touch/keys route to `emulator` when set, else to the agent `control`. `inputLive` gates both. |
| `AppDelegate` | `startEmulatorHost(for:)`, branch in `startSession`, `perform(action:)` | If `device.isEmulator && AppBuild.emulatorHostEnabled` and a port + bridge are found → host; otherwise falls back to the adb/agent path silently (logged). |
| Gate | `AppBuild.emulatorHostEnabled` | `RPLAYHUB_EMU=1` env or `EmulatorHostEnabled` default. Off by default: shipping builds carry no behaviour change. |
| Bundling | `tools/gen-xcodeproj.py` (Release bundle phase), `tools/package-dmg.sh` | Copies `emulator-transport/.build/arm64-apple-macosx/{release,debug}/emulator-bridge` to `Contents/MacOS/emulator-bridge`, signed with `adb-inherit.entitlements` like adb (it needs the app's `network.client` inside the sandbox). Missing binary = warning + adb fallback, never a build failure. |

## How the port is found (no configuration)

The emulator writes a discovery file per running instance — the same files Studio reads:
`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` (also `$XDG_RUNTIME_DIR/avd/running`).
It has `port.serial=5554` (→ adb serial `emulator-5554`), `grpc.port=8554`, `avd.name`, the
`cmdline`, and `grpc.token`/`grpc.jwks` when auth is on. `EmulatorSession.discoverGrpcPort(serial:)`
matches `port.serial` to the serial and returns `grpc.port`. `RPLAYHUB_EMU_PORT` overrides.

## Input mapping (what "AS does the same" means concretely)

`KeyboardEvent.key` takes **DOM key values**, not Android keycodes — the table is compiled into
`qemu-system-aarch64-headless` (`strings … | grep GoHome`). Control strip → `GoBack`, `GoHome`,
`AppSwitch`, `Power`, `AudioVolumeUp/Down`; keyboard → `Enter`, `Backspace`, `Delete`, `Tab`,
`Arrow*`, `Home`, `End`; typed characters go as `KeyboardEvent.text`. Rotate is
`setPhysicalModel(ROTATION, [0,0,z])`, z = −90·quadrant. Touch is `sendTouch` with pressure 1
(down/move) / 0 (up) on identifier 0; coordinates are display pixels, which is what `MirrorView`
already produces because displaySize == frame size. Screenshot and Record stay on adb.

## Build / run / test

```sh
# bridge (once, or after changing emulator-transport/)
cd emulator-transport && swift build -c release --product emulator-bridge

# emulator, headless with gRPC (an emulator started by Studio/CLI without -grpc has no port)
$SDK/emulator/emulator -avd rplay-test -no-window -no-snapshot -grpc 8554 -gpu swiftshader_indirect &
# wait for BOTH: adb shell getprop sys.boot_completed == 1  AND  nc -z 127.0.0.1 8554

# app, gate on (Debug builds have no bundle phase, so point at the bridge)
python3 tools/gen-xcodeproj.py && xcodebuild -project app/rPlayHubAndroid.xcodeproj \
  -scheme rPlayHubAndroid -configuration Debug -derivedDataPath build/dd build
RPLAYHUB_EMU=1 RPLAYHUB_EMU_BRIDGE=$PWD/emulator-transport/.build/arm64-apple-macosx/release/emulator-bridge \
  nohup build/dd/Build/Products/Debug/rPlayHubAndroid.app/Contents/MacOS/rPlayHubAndroid &
# select the emulator → View Screen. Log: ~/Library/Logs/rPlayHubAndroid/rplayhub-android.log
#   "emulator: bridge up on gRPC :8554" then "emulator: frame 1080x2424"
```

A bridge-only smoke test that needs no app: spawn `emulator-bridge 8554`, read frames, write
`{"press":"GoHome"}` / `{"rotate":-90}` — after rotate the next frame is 2424×1080. (The stream
pushes on change, so a single blocking read lags the command by a frame; that is not a bug.)

`$SDK` = your Android SDK root (the homebrew `android-commandlinetools` install works). Any AVD
will do; the notes above use one called `rplay-test`.

## Traps

- Boot races: connecting before `boot_completed` and before the gRPC port is listening gives
  "device not found" / connection refused. Always wait for both.
- `emulator-bridge` must be built with `swift build`; the app's xcodeproj knows nothing about the
  package on purpose. The Release bundle phase only copies what exists.
- gRPC auth: with `-grpc <port>` there is no token (localhost, allow-list in
  `lib/emulator_access.json`). An emulator started *without* `-grpc` uses a token/JWT
  (`grpc.token`/`grpc.jwks` in the discovery file); the exact header format was not made to work
  in the spike (`authorization: Bearer <tok>` was rejected). Solve before hosting emulators the
  app did not launch.
- PNG frames are ~1.8 MB each at 1080×2424; decode is on the session's queue, presentation on
  main. Fine for a spike, not the end state (see next steps).
- SourceKit shows "No such module" for the package files inside Xcode — it isn't in the project;
  `swift build` is the truth.
- The earlier `{"key":"KEYCODE_*"}` bridge command is legacy; the emulator's key sender wants
  DOM names (`press`).

## Next steps, in order

1. **Launch from the app ("+ Emulator")** — list AVDs (`emulator -list-avds` / `~/.android/avd`),
   launch `-no-window -no-snapshot -grpc <free port> -gpu auto`, wait for boot + port, then host.
   DMG-only (the sandboxed App Store build cannot exec the SDK's emulator); the emulator itself
   stays external — downloaded/installed by the user or via sdkmanager, never bundled.
2. **Frame path** — ask `streamScreenshot` for a smaller `RGBA8888`/`RGB888` image at the window's
   scale (skip PNG), or move to the emulator's WebRTC/`Rtc` service for a real video stream.
3. **Input polish** — scrollWheel (currently agent-only), multi-touch, mouse buttons; the
   emulator also accepts `sendMouse`.
4. **Auth** for emulators started elsewhere (token/JWT from the discovery file).
5. **Fusion on a hosted emulator** — `setDisplayConfigurations` can add displays; decide whether
   fusion windows should use them or keep the adb/agent path (the agent path still works since
   adb is live).
6. Parked: the from-source Qt-stripped engine (Linux AOSP tree, cross-compile to Mac) — only if
   Google's binaries prove limiting.
