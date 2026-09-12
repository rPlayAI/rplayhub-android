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
- Two-display streaming approach (one agent or two): _pending_ (the agent's StartVideoStream
  takes any display id; the outer panel is logical display 3 while open, and logical display 0
  swaps to the outer panel when CLOSED; not yet exercised)
- Default constants (`d`, `a`, `r_max`, `k`, `w`): _pending_
- Angle below which `stylized` diverges from `locked`: _pending_
- Path of the exported calibration JSON handed to the SF agent: _pending_
