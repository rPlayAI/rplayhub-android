# rPlayHub Android — Fold Twin Prototype Brief

Brief for the agent(s) working in `rplayhub-android`. Goal: turn the experimental 3D device twin into a prototyping rig for a hinge-driven fold/unfold animation on Pixel Fold, so the projection math, blur/translucency look and curve constants can be tuned on the Mac before they are hardcoded into the SurfaceFlinger demo (see `pixel-fold-unfold-animation-design.md`, Part A, task D3).

Status: draft, 2026-09-11. Owner: Huihong. Target: macOS app only; Linux/Windows ports are out of scope.

---

## 0. Why the twin

In the twin the camera is the viewer, so "content stays locked in space while the phone moves" has an exact definition: a fixed content plane in the world, and each half's glass shows whatever the camera sees of that plane through the rotating panel. That render is ground truth. Because both the glass and the content plane are planar, the glass-to-content mapping is a homography (3×3 projective), which is exactly what SF's per-layer `mat4` will carry. The twin lets us derive that homography numerically, compare it against a stylized approximation, and tune blur/alpha, all with no SF build cycle.

What the twin cannot do: prototype latency. The mirror stream and the on-device hinge sensor add tens of ms. Tune the look here; tune timing on the SF branch. Do not "fix" lag in the twin by adding prediction; that hides the number we want to measure elsewhere.

---

## 1. What exists today (from README)

- 3D twin: single rigid phone model, orientation from the device rotation vector, mirror texture-mapped onto the glass, orbit camera, re-centre calibration (R). Gated by `RPLAYHUB_TWIN=1` or View ▸ 3D Device Twin.
- Our agent build streams 50 Hz quaternions on a fourth socket when flag `0x100` is set (`refs/studio/PROVENANCE.md` records the modification).
- `RPLAYHUB_FAKE_GYRO=1` replaces the sensor with scripted poses.
- The agent can mirror a chosen display (Desktop Mode / virtual displays use this).

---

## 2. Changes

### 2.1 Agent (`refs/studio/`, our modifications; keep them recorded in `PROVENANCE.md`)

1. On the `0x100` sensor channel, also enable `ASENSOR_TYPE_HINGE_ANGLE` (type 36) at its fastest supported rate. It is on-change; samples arrive only while the angle moves.
2. Enumerate the sensor list once at channel start and log it (type, name, vendor, min delay, reporting mode). On a Fold, look for a second gyroscope exposed as a vendor sensor. If present, enable both gyros at max rate.
3. Packet format on the fourth socket: prefix each sample with a sensor-type tag and the sensor timestamp (`ASensorEvent.timestamp`, boot ns) so the host can interleave quaternion, hinge and gyro streams and align them to video frames.
   - `0x01` rotation vector (existing quaternion payload)
   - `0x02` hinge angle: float degrees
   - `0x03` gyro A, `0x04` gyro B: 3 floats rad/s (only if available)
4. Stream two displays at once: the inner (default) and the cover. Use the agent's existing display selection; if a single agent instance cannot serve two displays, launch a second instance for the cover display. Document which approach worked.

### 2.2 Host (`app/`, Swift + AppKit)

**Model**
- Replace the rigid phone with two hinged halves. Half A (held, contains the main IMU) takes the rotation-vector pose as today. Half B = half A rotated by (180° − hinge) about the hinge axis. Hinge axis and the offset of each glass quad from the hinge are per-device constants in one place; ship Pixel Fold values, keep the rigid single-body model for non-foldables.
- If two gyros are available, compute the moving fraction `s = |ω_B·ĥ| / (|ω_A·ĥ| + |ω_B·ĥ| + ε)` and attribute the fold rotation to the halves accordingly (`φ_B = s·φ`, `φ_A = (1−s)·φ`), so the held half stays still in the world. If only one gyro, assume `s = 1` toward half B.
- Textures: inner display stream mapped across both halves' inner glass (split at the crease); cover display stream on the outer face of the cover half.

**Three render modes**, switchable mid-motion (menu + key), each writing its own atrace-style log line with the angle it rendered at:
1. `hardcut`: what Android does today. Cover texture until the threshold angle, then inner texture, no transform.
2. `locked`: physically locked ground truth. A fixed content plane in the world (place it where the fully-open inner display would be, in the held half's frame). Each glass fragment samples the content plane at the intersection of the camera→fragment ray with that plane (projective texturing). Cover glass samples the same plane, mirrored appropriately for its face.
3. `stylized`: the SF approximation. Per-half 4×4 `P = T(hinge) · Persp(d) · Ry(φ_half) · T(−hinge)` applied to the texture mapping, plus alpha ramp `1 − a·sin(φ_B)` and blur radius `min(r_max, k·sin(φ_B))` on the moving half, plus a seam blur band of width `w` at the crease. All five constants (`d`, `a`, `r_max`, `k`, `w`) live in a small inspector panel with sliders and can be saved/loaded as JSON.

**Fake hinge**
- Extend `RPLAYHUB_FAKE_GYRO` scripts with a hinge track: closed → open over N ms with an ease, and a flipped-grip variant (`s` script). Same script must replay identically across the three modes for side-by-side captures.

**Export**
- `Export fold calibration…` writes JSON: the five stylized constants, and for each 5° of hinge angle the numeric 3×3 homography that `locked` mode implies for half B (and half A when `s < 1`), embedded as a 4×4 (x, y, w; z untouched). This file is the input to the SF demo curve (D3).
- Screen-record all three modes for a scripted open at a fixed camera pose (front-on at the calibrated viewing distance) and side-by-side them in one movie.

---

## 3. Acceptance

- With a Pixel Fold connected and `RPLAYHUB_TWIN=1`: opening the phone opens the model; the held half is still in the world when two gyros are available; the cover texture is on the outer face and the inner texture spans both inner faces with the seam at the physical crease.
- Sensor log at channel start lists the hinge sensor and any vendor gyro found on the Fold; the finding (one gyro or two) is written into this brief's §5.
- Mode switch during motion does not reset the pose or textures.
- `locked` mode: with the camera at the calibrated pose and the phone fully open, the inner texture is pixel-aligned with the fixed content plane (zero transform at 180°). At 90° the content on half B reads as a continuation of half A's content from the camera, not as a rotated copy.
- `stylized` mode with default constants is within visually small error of `locked` from the calibrated camera pose for angles ≥ 60°, and the residual is covered by the blur band. Record the angle below which the approximation breaks.
- Export produces the JSON and it round-trips into the inspector.
- Non-foldable devices are unaffected (rigid model, no new UI).

---

## 4. Non-goals

- Any latency measurement or prediction in the twin.
- Linux/Windows client parity.
- Changing the mirroring protocol for non-twin users; all additions are behind the existing `0x100` gate.

---

## 5. Findings (fill in)

- Fold sensor inventory (hinge rate, reporting mode, second gyro present?): Pixel 11 Pro Fold
  (yogi, Android 17): `Hinge Angle Sensor (wake-up)` type 36, on-change, min delay 20 ms,
  reports in 5-degree steps (a fold from flat to closed yields ~36 samples); two hardware IMUs,
  TDK ICM45631 and ICM45621, each with accelerometer + gyroscope at 2.5 ms min delay, so a
  second gyroscope IS present. Streamed by the Linux agent as tags 2, 3, 4 on the 0x100 channel;
  measured host arrival 15-40 ms apart during a fold over USB.
- Real fold sweeps (2026-09-15, Pixel 11 Pro Fold, network adb, hard-cut mode, four open/close
  cycles in the twin and in Fold View, read from the `fold:` trace): the sensor reports 0° shut
  and tops out at **175°** flat, in 5° steps that become 10° steps on a fast sweep (a whole open
  takes ~1 s). Postures switch at fixed angles in both directions: opening HALF_OPENED at 5°,
  OPENED at ~135°; closing HALF_OPENED at ~120°, CLOSED at ~35°. Android hands the mirror
  stream to the inner panel at **45–55° opening** (well after HALF_OPENED) and back to the cover
  at 0–30° after CLOSED; each handover landed on the right glass. The Mac's easing trails the
  sensor by 5–7° at a brisk open and up to 15° on a fast close, with no snap-back. Network adb
  survived every shut.
- Two-display streaming approach (one agent or two): _pending_ (the agent's StartVideoStream
  takes any display id; the outer panel is logical display 3 while open, and logical display 0
  swaps to the outer panel when CLOSED; not yet exercised)
- Default constants (`d`, `a`, `r_max`, `k`, `w`): _pending_
- Angle below which `stylized` diverges from `locked`: _pending_
- Path of the exported calibration JSON handed to the SF agent: _pending_

---

## 6. macOS implementation status (2026-09-14)

The twin on the Mac now builds a foldable as two hinged halves (`HeroComposer.makeFoldPhone`,
used by `TwinView` when the device announces device states over the control channel, or when
`RPLAYHUB_FAKE_HINGE` is set). First verified against the fake hinge with a test grid on the
glass, then live the same evening with the Pixel 11 Pro Fold over network adb: the agent streams
tags 1–4 (rotation vector, hinge, both TDK gyroscopes), the Mac reads the hinge (0° shut, 104°
mid-sweep), the posture arrives (six states, CLOSED → HALF_OPENED → OPENED) and shows in the
title bar, and the panel swap is handled — shut, the 1080×2342 cover stream lands on the cover
face; opening, the 2076×2152 inner stream spans both halves.

**How a device is known to fold.** Not by "it has device states": a Pixel 9a reports one state
named DEFAULT, and the agent forwards any non-empty list (controller.cc, `if
(!device_states.empty())`). A fold is a device whose vocabulary has more than one posture or
names one a hinge produces (`AgentSession.isFoldVocabulary`). The Pixel 9a therefore gets the
rigid twin.

- **Hinge.** Tag 2 from the sensor channel (28-byte tagged packets since 2026-09-11), eased at
  the same rate as the Linux client so the 5° steps read as one sweep. Tags 3/4 (the two
  gyroscopes) are read and exposed (`SensorStream.latestGyro`) but the model still assumes
  `s = 1`: half B moves, half A is held. §2.2's attribution is the next step.
- **Textures.** Panels told apart by shape (aspect ≥ 0.7 is the inner panel). The last inner
  frame stays on the inner glass once the stream moves to the cover; the last cover frame is kept
  so the next fold lights the cover before Android hands it over; before any cover frame exists
  the cover shows the middle half of the inner picture. Same policy as the Linux client.
- **Render modes** (View ▸ Fold Look, keys 1/2/3 with the 3D view focused, `RPLAYHUB_TWIN_MODE`
  for screenshots): `hardcut` as Android draws it; `locked` as a **per-fragment** Metal shader
  modifier on the moving half's inner glass AND on the cover (eye ray → content plane fixed to
  the held half → texture coordinate; the cover's plane is the cover as it lies when shut,
  anchored at its hinge-side edge), i.e. the exact homography rather than the 6×16 per-vertex
  grid of the Linux pass — verified: a circle across the crease stays round and a diagonal stays
  straight at 100°/140°, and the cover's lock screen stays put at 40°; `stylized` is the iPhone
  Duo look of §7 (2026-09-15): the same projection from a front-on eye fixed to the held half,
  plus the blur-and-darken gradient from the crease toward the moving edge, `smoothstep` gated
  over the 90° nearest each panel's home state, and — beyond the Duo — the moving half turns
  to glass while it moves: `glass · sin φ` of transparency on its body, inner screen and cover,
  so the held half's content shows through the frosted pane, opaque again flat and shut (its
  body materials are its own copies; it renders after the held half). Defaults blur=72 px,
  gamma=1.35, dark=0.2, gain=2, glass=0.45, seam band w=0
  (`RPLAYHUB_FOLD_STYLE='{"blur":..,"gamma":..,"dark":..,"gain":..,"glass":..,"w":..}'` to
  override). The readout hides itself 4 s after a mode change so a recording is clean. The inspector sliders and the JSON round-trip of §2.2 are not built yet; the
  env override stands in. `RPLAYHUB_FOLD_DEBUG=1` paints the projected (u, v) on the glass.
- **Fake hinge.** `RPLAYHUB_FAKE_HINGE=1` sweeps shut↔open, `=<degrees>` holds. With no phone at
  all, View ▸ View Screen in 3D still opens the rig on a 2076×2152 inner display showing a test
  grid (L / TOP / R, a circle and a diagonal across the crease), so the look can be tuned and
  screenshotted with nothing plugged in.
- **Touch** through either half's glass maps to the whole inner display.
- **Trace.** Every new hinge reading logs `fold: hinge N° (shown M°) <mode>` and every panel
  handover `fold: stream is now the INNER/COVER panel W×H at hinge N°`, so a real sweep leaves
  evidence in the log (a sweep is a few dozen lines). §5 records the first real sweeps.
- **Not done:** streaming inner and cover displays at once (§2.1 item 4 — still "pending" on
  both clients), gyro attribution (`s`), the calibration export (`Export fold calibration…`) and
  the side-by-side capture of the three modes. The brief's acceptance items that need a real
  Fold are open until one is on the Mac.

Trap recorded on the way: the Mac's `SensorStream` had kept the old 24-byte layout after the
agent moved to tagged 28-byte packets; it worked only because the bundled agent predated the
change. The two are now in step, and `tools/build-agent.sh` passes the locally installed NDK
version to Gradle so the same source builds on the Mac and the Linux host.

---

## 7. Against the iPhone Duo animation (2026-09-15)

Apple's iPhone Duo (announced 2026-09-09) ships the effect this brief prototypes: content stays
locked in space while the phone reorients around it, blurring toward the moving edge. Apple
documents nothing beyond "content reacts as it folds"; the best public spec is the Three.js
recreation at github.com/chuspeeism/iphone-duo (built on Apple's USDZ model), read line by line.

**Matches.** Rear/camera half held, cover half rotates, hinge on the left, cover on the moving
half's outer face — our `makeFoldPhone`. Their inner-screen shader intersects an eye→fragment ray
with the flat inner plane and samples there — our `locked` mode's homography. They use a FIXED
front-on reference eye (what a phone can ship, since it cannot know the viewer); we use the live
camera. The two coincide in Fold View.

**Differs — and this is the signature of the look.**
1. Blur + darkening gradient from the crease toward the free edge, no transparency:
   `radius = 72px · motion · edge^1.35`, `color *= 1 − min(1, 2·motion·((edge−0.2)/0.8)^1.35)`;
   at 90° the outer ~third of the moving half is black, the hinge side stays crisp and continuous
   with the held half, and the held half is untouched. Ours: a uniform `1 − a·sin φ` alpha fade
   and a seam band; no blur, no darkening.
2. `motion = smoothstep` over the 90° nearest the home state: inner crisp at flat and fully
   treated by 90° and beyond; cover crisp shut, fully treated by 90°, OFF at flat. Ours peaks at
   90° and recovers toward shut (`sin φ`).
3. Their cover is projected too — anchored at its hinge-side edge, sampled through the same eye,
   then blurred/darkened outward. Our cover face is always hard-cut (Android's own stream and
   its 45–55° handover).
4. They bend a crease strip (~4% of the width, Hermite); ours is a sharp hinge line.
5. The Duo's two displays share an aspect ratio, so the cover is a crop of the inner layout and
   the handover can be pixel-continuous; a Pixel Fold's cover runs a different layout, so the
   blur is what has to hide the crossover.

**Done the same day.** `stylized` is now the Duo shader (blur+darken gradient, smoothstep
gating, fixed reference eye) on the per-fragment Metal modifier, which also projects the cover
with the hinge-edge anchor in both locked and stylized; `72 / 1.35 / 0.2 / 2×` are env
overrides until the inspector exists. Verified against the fake hinge at 100°, 140° and 40°
with the test grid and the live cover. Two things the port taught: the treatment is faint near
90° because a front-on eye sees only a sliver of the moving half there — it peaks mid-sweep
(~135°), which is the reference's behaviour too; and the frames have no mip chain, so the blur
is a 9×9 binomial tap at a quarter of the radius instead of the reference's mip-level trick.
Same evening: the moving half also turns to translucent glass mid-fold (`glass`), and the
model's back is the Pixel 11 Pro Fold's — stacked camera pills in the corner away from the
hinge, read off the press render (`HeroComposer.makeFoldCameraIsland`). Still open: a real
sweep with eyes on stylized, and item 5 (the Pixel's cover runs its own
layout, so the crossover is never pixel-continuous).
