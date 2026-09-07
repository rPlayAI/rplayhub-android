# Hero render — where it stands and what "professional" would take

The Hero Composer puts the live mirrored screen on a 3D phone over a gradient with a headline and
a brand badge, and exports store-listing PNGs or video. This doc is the state of the render, the
competitive picture, and the ranked list of what is still missing.

**Status: parked, and deliberately so.** What exists is a demonstration that the idea works, not a
finished feature. Studio-grade rendering is intended for the **paid tier**, so it is worth having
proved out and worth nothing until the free product wins on its own ground. The priority is
**parity with scrcpy** — mirroring, control, latency, the things every user judges first. Nothing
below should displace that. Pick this up when the paid tier is the question being asked.

Code: `app/rPlayHubAndroid/HeroComposer.swift` (scene, chassis, passes),
`HeroPanel.swift` (the inspector's Hero tab), `TwinView.swift` (the live 3D twin, which shares the
chassis). Feature history is in the memory notes, not here.

## What exists

- **One chassis, two views.** `HeroComposer.makeHeroPhone` builds the phone; `TwinView` calls it
  and adds only the back-photo override. A hero shot swinging past the back sees what the twin
  sees when you turn the phone over.
- **Two-tone body.** SCNShape takes materials as front, back, side and the two chamfer profiles.
  The rail is a brighter, more polished metal than the faces, with the chamfer brighter still.
  That contrast is what makes an edge read; one uniform grey cannot, however good the lighting.
- **Real proportions.** Thickness over width is 0.116. A Pixel 9 is 8.5 mm thick and 72 mm wide,
  about 0.118, and every current handset lands near that. We were at 0.068 and the rail read as a
  line rather than a rail.
- **Camera island** inset from both rails with recessed black glass, three lens barrels, a sensor
  and a flash, plus the G below. Proportions read off `doc/pixel-backside.png`.
- **Finishes** (graphite, midnight blue, desert sand, silver), a clean status bar via SystemUI
  demo mode over adb, an accent colour sampled from the screen, and a soft drop shadow.
- **Parametric.** The body is built from the display's aspect ratio, so it fits a phone, a tablet
  or a landscape car head unit. This is the property most worth protecting.

## Two lessons that cost time

**Under physically based shading the environment supplies the specular; lights only add diffuse.**
Four lights at 700–1300 lifted a charcoal back to flat mid grey that read as painted plastic.
They are now roughly a third of that, with the environment turned up. If a surface looks like
plastic, turn lights *down*, not up.

**A rounded rail reflects a picture of the room, squeezed.** So the environment map is a near-black
field carrying a few narrow, hard-edged bright strips. A wide soft glow smears into a broad
gradient; a narrow hard strip reflects as the razor-thin rim line, and it brightens through the
corners on its own as the surface turns.

## The competitive picture

**3D Phone Studio** (`github.com/Nathan112267/3d-phone-studio`, closed source) appeared the same
week. Electron with React and WebGL, an iPhone companion on TestFlight, and a bundled GPL AirPlay
receiver to get the screen in. It ships seven camera angles, six named director moves, six animated
backgrounds, three body colours, 4K stills and 2K video, behind a three-pill interface.

What is worth taking from it:

- **Their edge quality is two-tone materials, not lighting.** Confirmed in their own model file:
  the frame is nearly black with low metalness, and the metal look comes entirely from the
  environment.
- **Their glass is real glass**, declaring the transmission and IOR extensions. That is the one
  thing their render has that ours does not.
- **Their live path is worse than ours.** AirPlay capped at 1080p, started by hand from Control
  Centre with a password, needing a companion app. We take the phone's native stream over a cable
  and can also control the device.
- **Their model is Creative Commons non-commercial share-alike**, which is why their whole beta is
  non-commercial. That is the licence trap to stay out of.

## Ranked: what would make it professional

Geometry is about sixth. The gap is rendering technique, and nearly all of it is code.

1. **Cover glass with refraction.** The screen should sit *under* something: a transmissive layer
   with an index of refraction, offsetting the image slightly and carrying a specular sweep as the
   phone turns. The single biggest tell. SceneKit needs a shader modifier; its built-in
   transparency will not do refraction.
2. **Depth of field.** Every product shot is taken with a lens, so the far rail and the ground go
   soft. SceneKit's camera does this natively with a focus distance and an f-stop. A handful of
   lines, and it changes the read from render to photograph.
3. **Tone mapping.** We composite straight to sRGB, so highlights clip flat where a real render
   rolls off into white. The chamfer line is almost certainly clipping today. One of the clearest
   amateur tells once you know to look for it.
4. **A real environment.** The hard-strip map works, but a studio HDRI gives reflections with
   structure and colour instead of grey bars. Poly Haven publishes them CC0 — no licence trap.
5. **A true contact shadow** cast in 3D, rather than the blurred 2D silhouette we composite now,
   so the phone sits on something.
6. **Geometry.** Subtle body curvature, an exact chamfer profile, a modelled grille.

Suggested order if it is ever picked up: glass, then depth of field and tone mapping together,
then the environment. Roughly two days, no assets, no licence conversation.

## On Blender models

Not yet, and the reasons are worth keeping:

- **A mesh is one device shape.** Our chassis adapts to whatever is plugged in. Theirs renders
  every iPhone as an iPhone 17 Pro for exactly this reason. Do not trade that away.
- **Licensing.** A borrowed model can make the whole product non-commercial.
- **It is not the bottleneck.** Five items above it matter more, and all are code.
- **SceneKit does not read GLB** — USDZ, DAE and SCN only — so any Blender asset needs conversion,
  a loader path and a fallback.

If per-device accuracy is wanted later, the shape to build is an *optional* model dropped in a
folder and keyed by the device's model name, with the procedural chassis as the fallback. That is
the same pattern as the twin's back-photo override, so the fallback story is already written.

## Practical notes for whoever picks this up

- The phone sleeps between renders and the hero screen dumps black. Run
  `settings put global stay_on_while_plugged_in 7` first.
- A back view mirrors left and right. The flash belongs on the phone's left rail, which appears on
  the right of a back render. Easy to build backwards.
- Dev hooks: `RPLAYHUB_HERO_DUMP=<png>` writes one full-size render after the first live frame,
  `RPLAYHUB_HERO_DUMP_MP4=<mp4>` records a few seconds of the orbit, and
  `RPLAYHUB_HERO_STYLE='{"yaw":152,"scale":0.7}'` overrides the pose numbers without rebuilding.
  Together they make a render-inspect-adjust loop that needs no clicking.
- Stills render the phone at 2x and downscale; recordings stay at 1x to hold frame rate.
