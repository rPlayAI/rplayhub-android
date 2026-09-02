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
| `EmulatorSession` | `app/rPlayHubAndroid/EmulatorSession.swift` | App side. Discovers the gRPC port, spawns the bridge, parses frames → BGRA `CVPixelBuffer` on its own queue (scaled RGB888 via vImage by default, PNG when `scaledTo` is nil), exposes `onFrame(buffer, frameSize, displaySize)`/`onExit`; `setSize` re-requests the stream on resize; input helpers (`sendTouch`, `press`, `type`, `rotate`, `perform(ControlStrip.Action)`) and the AndroidKey → DOM-key map. |
| `MirrorView` | `present(picture:size:)`, `var emulator` | The frame is its own geometry (videoSize = displaySize = frame pixels; rotation shows up as a landscape frame). Touch/keys route to `emulator` when set, else to the agent `control`. `inputLive` gates both. |
| `AppDelegate` | `startEmulatorHost(for:)`, branch in `startSession`, `perform(action:)` | If `device.isEmulator && AppBuild.emulatorHostEnabled` and a port + bridge are found → host; otherwise falls back to the adb/agent path silently (logged). |
| Gate | `AppBuild.emulatorHostEnabled` | `RPLAYHUB_EMU=1` env or `EmulatorHostEnabled` default. Off by default: shipping builds carry no behaviour change. |
| `EmulatorLauncher` | `app/rPlayHubAndroid/EmulatorLauncher.swift` | "+ Emulator". `AndroidSdk` (SDK root + AVD home resolution, ini parsing), `Avd` (the list, from `<avd home>/*.ini` + `config.ini`), `EmulatorLauncher` (free ports, headless launch, wait, shut down). Gate `AppBuild.emulatorLaunchEnabled` = host gate **and not sandboxed** (`APP_SANDBOX_CONTAINER_ID` unset) — DMG-only by construction. |
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

## "+ Emulator" (launch from the app)

The sidebar's `+` becomes a menu when the launch gate is on: **Connect to Device over Network…**,
then **Start Emulator** with one entry per AVD (`displayname`, subtitle "Pixel 9 · API 35 ·
arm64-v8a"; a running one is checked and disabled with its serial, one being started says so),
then **Locate Android SDK…** (folder picker, saved as the `AndroidSdkRoot` default). With the gate
off `+` is the plain connect dialog it always was.

What a launch does (`EmulatorLauncher.launch`):

1. SDK root = `AndroidSdkRoot` default → `$ANDROID_HOME`/`$ANDROID_SDK_ROOT` → `~/Library/Android/sdk`
   → the homebrew `android-commandlinetools` → the SDK the found adb lives in; the first with
   `emulator/emulator`. AVD home the way the emulator resolves it (`ANDROID_AVD_HOME`,
   `ANDROID_USER_HOME/avd`, `ANDROID_SDK_HOME/.android/avd`, `~/.android/avd`).
2. Ports by bind test on loopback: console = first even port in 5554–5682 with its adb port
   (+1) free too; gRPC = first free from 8554. Fixing `-port` means the serial is known before
   the engine is up, so the sidebar can show a row for it at once.
3. `emulator -avd <name> -port <c> -no-window -no-snapshot -grpc <g> [-gpu host]`, stdout/err to
   `~/Library/Logs/rPlayHubAndroid/emulator-<avd>.log`, `RPLAYHUB_*` scrubbed from its env.
   **GPU**: with `-no-window`, `-gpu auto` resolves to software (`emuglConfig_init:
   vulkan_mode_selected:lavapipe gles_mode_selected:swangle`). `-gpu host` headless works on
   Apple silicon (ANGLE over Metal, "Graphics Adapter … (Apple M2 Max)"), so the launcher passes
   `host` unless the AVD's `config.ini` pins `hw.gpu.mode` to something other than `auto`.
4. Wait: discovery file (`pid_<pid>.ini` — the `emulator` launcher execs the engine in place, so
   the pid is ours; falls back to matching `port.serial`) + TCP connect on the gRPC port (about
   1 s), then `adb devices` listing the serial as `device` (about 10 s on this Mac). Meanwhile the
   sidebar shows "Emulator · <avd>" with a spinner and the phase; adb's few seconds of `offline`
   for that serial are hidden behind that row rather than shown as "reconnect the cable".
5. On ready: the row is selected (prepare-on-select hosts it) and the mirror is revealed — the
   boot animation is what you see first. Home screen at roughly 30 s after the click.

Before launching, the launcher writes **`hw.keyboard=yes`** into the AVD's `config.ini` if it is
`no`. With `no` the engine creates no keyboard input device in the guest (only `gpio-keys` and
the `virtio_input_multi_touch_*` devices exist), so every key path is dropped silently —
`sendKey` over gRPC *and* the console's `event send`; only touch arrives. An `avdmanager`-made
AVD inherits `no` from the phone device profile; Studio's Device Manager writes `yes`, which is
why Studio never sees it. Symptom: the control strip and keyboard do nothing while touch works.
Diagnose with `dumpsys input | grep -E '^ +[0-9]+: '` — a working guest lists `qwerty2`.

**Screen shape on a hosted emulator.** The punch hole in the picture is in the stream: the Pixel
profile reports a cutout and the emulator's SystemUI overlay paints it black into the framebuffer
(`ScreenDecorOverlay`, `touchableRegion=[485,0][595,142]`), unlike a real Pixel where the hole
is physical. The corners are ours: `loadDisplayShape` now runs for a hosted emulator too (adb is
live), with a retry loop because the first frame arrives seconds into boot, before system_server
answers `dumpsys display`. rplay-test reports r=132 and a circle at (539.5, 86.5) r 42 — the mask
lands exactly on the painted hole.

Shutting down: the emulator row's context entry **Shut Down Emulator** (the Disconnect slot,
retitled) — SIGTERM for an instance we started (the engine exits cleanly), `adb -s <serial> emu
kill` for any other. If it is the hosted one, the host stops first so the bridge's exit is not
reported as a failure. **Quitting the app shuts down every emulator it started** (Studio does the
same for its embedded ones; a headless engine has no other face). Emulators started elsewhere are
left alone.

Stop Screen Mirroring on a hosted emulator now stops the bridge too (it used to leave it running);
View Screen re-hosts.

**Why DMG-only**: a sandboxed process cannot exec the SDK's emulator, so `tools/package-dmg.sh`
now builds the DMG **unsandboxed by default** (`DMG_SANDBOX=1` for the old shape; helpers are then
signed with no entitlements instead of sandbox+inherit). The store build (`archive-appstore.sh`)
stays sandboxed and never shows the entry. The emulator itself is never bundled.

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

1. ~~Launch from the app ("+ Emulator")~~ — shipped 2026-09-01, see above. Follow-ups: a
   snapshot (quick-boot) option instead of always `-no-snapshot`; "keep running after quit";
   showing the boot animation before adb is up (host on gRPC alone, with a placeholder row).
2. ~~Frame path~~ — shipped 2026-09-01. The bridge now streams **scaled RGB888** by default,
   not whole-display PNG: `emulator-bridge <port> --rgb <w>x<h>` asks `streamScreenshot` for an
   `RGB888` image fitted to the view (aspect kept; the engine scales and copies, no encode), and
   the app converts RGB888→BGRA with vImage (`vImageConvert_RGB888toBGRA8888`) — no PNG decode.
   Each frame is `[w][h][nativeW][nativeH]` (BE) + pixels; the native size (oriented like the
   frame) is what input maps into, since the stream is smaller than the display. The app requests
   the stage's pixel size and re-requests on resize (debounced 0.3 s; the bridge cancels and
   restarts the stream, Studio's model). `EmulatorSession(scaledTo:)` drives it; `RPLAYHUB_EMU_PNG=1`
   keeps the old whole-display PNG path. A ~730×1640 RGB frame is ~3.6 MB raw vs ~1.8 MB PNG but
   costs no encode/decode; the real win is skipping PNG on both ends and only sending view-sized
   pixels. WebRTC/`Rtc` remains an option for a true delta-coded video stream.
3. **Input polish** — scrollWheel (currently agent-only), multi-touch, mouse buttons; the
   emulator also accepts `sendMouse`.
4. **Auth** for emulators started elsewhere (token/JWT from the discovery file).
5. **Fusion on a hosted emulator** — `setDisplayConfigurations` can add displays; decide whether
   fusion windows should use them or keep the adb/agent path (the agent path still works since
   adb is live).
6. Parked: the from-source Qt-stripped engine (Linux AOSP tree, cross-compile to Mac) — only if
   Google's binaries prove limiting.
