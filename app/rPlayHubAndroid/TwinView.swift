//
//  TwinView.swift
//  The device twin: the live mirror on a 3D phone that moves like the phone in your hand.
//
//  Not a second viewer — a display mode. "View in 3D" swaps this view into the mirror's place
//  in the main window and hides the flat view; exiting swaps them back. One stream, one window,
//  one picture on screen at a time; the button strip underneath keeps working either way.
//
//  Three inputs meet here. Decoded frames arrive from the decode thread (BGRA — the decoder is
//  switched to Metal-friendly output while this mode is active) and become the screen texture
//  through a CVMetalTextureCache, zero copies. Rotation vector quaternions from the sensor
//  channel drive the phone node's orientation, slerp-smoothed to kill sensor jitter. Packet
//  headers say which way the picture should sit on the physical panel — a real phone's panel is
//  glued in place; it is the OS that rotates the UI, so landscape content is painted onto the
//  portrait panel rotated, exactly like the glass.
//
//  Orientation is shown relative to a reference pose, captured when the mode opens and again
//  whenever the user re-centres (R, or the button): however the phone sits at that moment
//  becomes "facing you". Absolute yaw is East-North-Up — meaningless across a desk — and the
//  game rotation vector fallback has arbitrary yaw anyway. Dragging orbits the camera; input
//  injection stays with the flat view.
//

import AppKit
import CoreVideo
import Metal
import SceneKit
import simd

final class TwinView: NSView, SCNSceneRendererDelegate {
    /// Pulled once per rendered frame on the render thread; returns the newest device quaternion.
    var orientationSource: (() -> simd_quatf?)?

    private var scnView: TwinSCNView!
    private var phoneNode: SCNNode?
    private var screenMaterial: SCNMaterial?

    private var textureCache: CVMetalTextureCache?
    /// The CVMetalTexture wrappers must outlive the GPU's use of their MTLTextures; holding the
    /// last few is the standard trick.
    private var heldTextures: [CVMetalTexture] = []

    // Handed from the decode thread to the render thread; newest wins, same as the flat view.
    private let frameLock = NSLock()
    private var pendingFrame: CVPixelBuffer?
    private var isActive = false

    // Render-thread state.
    private var reference: simd_quatf?
    private var smoothed: simd_quatf?
    private var recenterRequested = true
    private var referenceSamples: [simd_quatf] = []
    /// The saved "facing me" calibration — the device pose that maps to the twin face-on. Set by
    /// the button (or R), persisted, and reused as the default on every later session so the twin
    /// starts in the right position instead of adopting whatever pose the phone happens to be in.
    private var savedFacingMe: simd_quatf?

    // Main thread writes on geometry changes, render thread reads.
    private let geometryLock = NSLock()
    private var textureQuadrants = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        let view = TwinSCNView(frame: bounds)
        view.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        view.allowsCameraControl = true          // drag to orbit, scroll to dolly — for free
        view.antialiasingMode = .multisampling4X
        view.delegate = self
        view.onRecenter = { [weak self] in self?.recenter() }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scnView = view

        if let metalDevice = view.device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache)
            textureCache = cache
        }

        // "Set Facing Me", not "Re-centre": the button's job is to declare the current pose as
        // the face-on default, and it persists that for later sessions.
        let recenterButton = NSButton(title: "Set Facing Me  (R)", target: self,
                                      action: #selector(recenterPressed))
        recenterButton.bezelStyle = .rounded
        recenterButton.controlSize = .small
        recenterButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recenterButton)
        NSLayoutConstraint.activate([
            recenterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recenterButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])

        // First-run prompt: with no saved reference, the twin has no way to know which way the
        // phone faces, so it must be told once. Shown until the user calibrates, then never again.
        hint.stringValue = "Hold your phone the way you want it to face you,\nthen press Set Facing Me"
        hint.alignment = .center
        hint.isEditable = false
        hint.isBordered = false
        hint.drawsBackground = true
        hint.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55)
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.maximumNumberOfLines = 2
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 8
        hint.isHidden = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: recenterButton.topAnchor, constant: -14),
            hint.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.9),
        ])
    }

    private let hint = NSTextField(labelWithString: "")

    // MARK: - mode lifecycle

    /// `displaySize` is the display in its canonical (portrait) orientation; it sets the body's
    /// proportions — rebuilt on each activation because a different device may be mirrored now.
    func activate(displaySize: CGSize) {
        scnView.scene = buildScene(displaySize: displaySize)
        scnView.rendersContinuously = true       // orientation changes without scene mutations
        // Prefer the saved "facing me" calibration as the default; only capture a fresh one from
        // the phone's live pose if the user has never set it.
        savedFacingMe = Self.loadFacingMe()
        reference = savedFacingMe
        // Never auto-capture: with no saved reference the twin can't know which way the phone
        // faces, so it waits — sitting face-on and inert — and prompts the user to calibrate.
        // Only pressing "Set Facing Me" captures. With a saved reference it tracks right away.
        recenterRequested = false
        referenceSamples = []
        hint.isHidden = savedFacingMe != nil
        smoothed = nil
        window?.makeFirstResponder(scnView)
        frameLock.lock()
        isActive = true
        frameLock.unlock()
    }

    func deactivate() {
        frameLock.lock()
        isActive = false
        pendingFrame = nil
        frameLock.unlock()
        scnView.rendersContinuously = false
        scnView.scene = nil
        phoneNode = nil
        screenMaterial = nil
        heldTextures = []
    }

    // MARK: - inputs

    /// Decode thread. Cheap when the mode is off: one lock, no retention.
    func present(_ pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        if isActive { pendingFrame = pixelBuffer }
        frameLock.unlock()
    }

    /// Main thread, on geometry changes. How many quadrants the arriving picture is rotated
    /// relative to the physical panel — the texture is counter-rotated to sit like real glass.
    func apply(header: VideoPacketHeader) {
        let quadrants = (Int(header.displayOrientation) - Int(header.displayOrientationCorrection) + 4) % 4
        geometryLock.lock()
        textureQuadrants = quadrants
        geometryLock.unlock()
    }

    func recenter() {
        referenceSamples = []
        recenterRequested = true
    }

    @objc private func recenterPressed() {
        recenter()
    }

    // MARK: - the scene

    private func buildScene(displaySize: CGSize) -> SCNScene {
        let scene = SCNScene()

        let aspect = displaySize.width > 0 && displaySize.height > 0
            ? displaySize.width / displaySize.height
            : 9.0 / 19.5
        let bodyHeight: CGFloat = 1.5
        let bodyWidth = bodyHeight * aspect * 1.06        // a slim bezel beyond the panel
        let bodyDepth = bodyWidth * 0.10

        let body = SCNBox(width: bodyWidth, height: bodyHeight, length: bodyDepth,
                          chamferRadius: bodyWidth * 0.07)
        let shell = SCNMaterial()
        shell.diffuse.contents = NSColor(calibratedWhite: 0.13, alpha: 1)
        shell.specular.contents = NSColor(calibratedWhite: 0.6, alpha: 1)
        shell.shininess = 0.6
        body.materials = [shell]

        let phone = SCNNode(geometry: body)

        // The panel floats a hair in front of the body. Unlit: it is a light source, not a
        // surface — the video should not dim as the phone tilts away from the key light.
        let panel = SCNPlane(width: bodyHeight * aspect, height: bodyHeight)
        let screen = SCNMaterial()
        screen.lightingModel = .constant
        screen.diffuse.contents = NSColor.black
        screen.isDoubleSided = false
        panel.materials = [screen]
        let panelNode = SCNNode(geometry: panel)
        panelNode.position = SCNVector3(0, 0, bodyDepth / 2 + 0.002)
        phone.addChildNode(panelNode)
        screenMaterial = screen

        // A camera-hole dot, purely so the top of the device reads as "top" from any angle.
        let dot = SCNNode(geometry: SCNSphere(radius: bodyWidth * 0.022))
        dot.geometry?.firstMaterial?.diffuse.contents = NSColor.black
        dot.position = SCNVector3(0, bodyHeight * 0.44, bodyDepth / 2 + 0.004)
        phone.addChildNode(dot)

        // The camera bar across the back — the Pixel's signature, and it makes the back a back
        // instead of an anonymous dark slab when the twin turns around.
        let barHeight = bodyHeight * 0.105
        let bar = SCNBox(width: bodyWidth * 0.92, height: barHeight, length: bodyDepth * 0.75,
                         chamferRadius: barHeight * 0.35)
        let barMaterial = SCNMaterial()
        barMaterial.diffuse.contents = NSColor(calibratedWhite: 0.08, alpha: 1)
        barMaterial.specular.contents = NSColor(calibratedWhite: 0.7, alpha: 1)
        barMaterial.shininess = 0.8
        bar.materials = [barMaterial]
        let barNode = SCNNode(geometry: bar)
        barNode.position = SCNVector3(0, bodyHeight * 0.35, -bodyDepth / 2 - bodyDepth * 0.18)
        phone.addChildNode(barNode)

        // Two lenses and a flash dot on the bar, facing backwards.
        let lensMaterial = SCNMaterial()
        lensMaterial.diffuse.contents = NSColor(calibratedWhite: 0.02, alpha: 1)
        lensMaterial.specular.contents = NSColor.white
        lensMaterial.shininess = 1
        for (offset, radius) in [(-0.30, 0.055), (-0.14, 0.055)] {
            let lens = SCNCylinder(radius: bodyWidth * radius, height: bodyDepth * 0.1)
            lens.materials = [lensMaterial]
            let lensNode = SCNNode(geometry: lens)
            lensNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)   // axis along z, face out the back
            lensNode.position = SCNVector3(bodyWidth * offset, bodyHeight * 0.35,
                                           -bodyDepth / 2 - bodyDepth * 0.58)
            phone.addChildNode(lensNode)
        }
        let flash = SCNNode(geometry: SCNSphere(radius: bodyWidth * 0.02))
        flash.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.85, alpha: 1)
        flash.position = SCNVector3(bodyWidth * 0.32, bodyHeight * 0.35,
                                    -bodyDepth / 2 - bodyDepth * 0.56)
        phone.addChildNode(flash)

        // The "G" on the lower back, as a real Pixel wears it: not the colour logo but a
        // monochrome polished-metal G etched into the panel, the same tone as the body, catching
        // the light as the phone turns. A metallic material (not constant) gives it that glint;
        // the mask is a single-colour G facing -z out of the back.
        let gSize = bodyWidth * 0.34      // a bold, clearly-readable G, no plate behind it
        let gPlane = SCNPlane(width: gSize, height: gSize)
        let gMaterial = SCNMaterial()
        gMaterial.lightingModel = .physicallyBased
        gMaterial.diffuse.contents = NSColor(calibratedWhite: 0.62, alpha: 1)   // polished aluminium
        gMaterial.metalness.contents = 1.0
        gMaterial.roughness.contents = 0.28       // brushed-metal sheen that glints as it turns
        // rgbZero: transparency comes from the mask's luminance, so the black background is fully
        // transparent and ONLY the G stroke carries the material — otherwise the whole square
        // plane would show as a metal patch.
        gMaterial.transparent.contents = Self.pixelGMask(side: 512)   // the G shape, white on black
        gMaterial.transparencyMode = .rgbZero
        gMaterial.isDoubleSided = false
        gPlane.materials = [gMaterial]
        let gNode = SCNNode(geometry: gPlane)
        gNode.position = SCNVector3(0, -bodyHeight * 0.12, -bodyDepth / 2 - 0.001)
        gNode.eulerAngles = SCNVector3(0, CGFloat.pi, 0)   // turn to face out the back
        phone.addChildNode(gNode)

        scene.rootNode.addChildNode(phone)
        phoneNode = phone

        let camera = SCNCamera()
        camera.fieldOfView = 40
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 3.1)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 700
        key.eulerAngles = SCNVector3(-0.5, 0.4, 0)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 350
        scene.rootNode.addChildNode(ambient)

        return scene
    }

    // MARK: - per-frame

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        updateTexture()
        updateOrientation()
    }

    private func updateTexture() {
        frameLock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        frameLock.unlock()
        guard let frame, let cache = textureCache else { return }
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else {
            return   // pre-switch YCbCr frame still in flight; the next keyframe brings BGRA
        }

        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, frame, nil, .bgra8Unorm_srgb,
            CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), 0, &wrapper)
        guard status == kCVReturnSuccess, let wrapper,
              let texture = CVMetalTextureGetTexture(wrapper) else { return }

        heldTextures.append(wrapper)
        if heldTextures.count > 3 { heldTextures.removeFirst() }

        screenMaterial?.diffuse.contents = texture
        screenMaterial?.diffuse.contentsTransform = textureTransform()
    }

    /// The panel counter-rotation from `apply(header:)`, as explicit affine maps of the unit
    /// square onto itself. Two lessons paid for in screenshots: the SCNMatrix4 concatenation
    /// helpers compose in an order that quietly sends coordinates outside 0..1, where clamped
    /// sampling smears the edge row across the panel — so the maps are written out by hand; and
    /// Metal textures from a CVMetalTextureCache land in SceneKit already upright, so the usual
    /// "Core Video is top-left origin" flip must NOT be applied — with it, the dock renders at
    /// the top of the panel and the status bar mirrors at the bottom.
    private func textureTransform() -> SCNMatrix4 {
        geometryLock.lock()
        let quadrants = textureQuadrants
        geometryLock.unlock()

        // u' = m11·u + m21·v + m41 ; v' = m12·u + m22·v + m42
        var m = SCNMatrix4Identity
        switch quadrants {
        case 1:  (m.m11, m.m12, m.m21, m.m22, m.m41, m.m42) = (0, -1, 1, 0, 0, 1)
        case 2:  (m.m11, m.m12, m.m21, m.m22, m.m41, m.m42) = (-1, 0, 0, -1, 1, 1)
        case 3:  (m.m11, m.m12, m.m21, m.m22, m.m41, m.m42) = (0, 1, -1, 0, 1, 0)
        default: break   // portrait stream on the portrait panel — identity
        }
        return m
    }

    private func updateOrientation() {
        guard let q = orientationSource?() else { return }
        if recenterRequested {
            // Average a short burst rather than trust one packet: a hand is never perfectly still
            // at the instant of a button press, and a noisy reference tilts everything after it.
            if referenceSamples.isEmpty || simd_dot(referenceSamples[0].vector, q.vector) >= 0 {
                referenceSamples.append(q)
            } else {
                referenceSamples.append(simd_quatf(vector: -q.vector))   // q and -q are the same
            }                                                             // rotation; align first
            if referenceSamples.count >= 12 {
                var acc = simd_float4(repeating: 0)
                for s in referenceSamples { acc += s.vector }
                let averaged = simd_quatf(vector: simd_normalize(acc))
                reference = averaged
                savedFacingMe = averaged
                Self.saveFacingMe(averaged)     // the default "facing me" for every later session
                referenceSamples = []
                recenterRequested = false
                smoothed = nil
                let v = averaged.vector
                AppBuild.log(String(format: "twin: facing-me reference set — gyro (%.4f, %.4f, %.4f, %.4f)",
                                    v.x, v.y, v.z, v.w))
                DispatchQueue.main.async { [weak self] in self?.hint.isHidden = true }
            }
            return   // hold the current pose until the reference settles
        }
        // The reference is the device pose the user chose as "facing me" — held facing the Mac
        // and captured with the button (or R), then persisted so it is the default next time.
        // What renders is the rotation FROM that reference TO the current pose, so at the
        // reference the twin is exactly face-on, and any real rotation of the phone shows as the
        // same rotation of the twin. Because it is a true rotation delta (not an attitude reset)
        // gravity stays honest: tilt the top toward you and the twin's top comes toward you.
        //
        // Android's rotation vector lives in an East-North-Up world (x east, y north, z sky);
        // SceneKit's is x right, y up, z toward the viewer. Rotating the world -90° about x maps
        // one onto the other, so the delta is conjugated through that map to act on SceneKit axes.
        let ref = reference ?? q
        let delta = q * ref.inverse
        let worldFix = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        let target = worldFix * delta * worldFix.inverse

        // Adaptive smoothing, so accuracy does not fight latency. A fixed slerp is a bad
        // compromise: gentle enough to kill the small jitter of a still phone, it visibly lags a
        // fast turn; snappy enough to track a fast turn, it shivers when still. Instead the blend
        // scales with how far the pose moved this frame — near-still frames get heavy smoothing,
        // fast frames get almost none — which reads as both steady and immediate.
        if let s = smoothed {
            let dot = min(1, abs(simd_dot(s.vector, target.vector)))
            let stepDegrees = Float(2 * acos(dot) * 180 / .pi)   // angle between s and target
            let alpha = simd_clamp(0.18 + stepDegrees * 0.28, 0.18, 0.9)
            smoothed = simd_slerp(s, target, alpha)
        } else {
            smoothed = target
        }
        phoneNode?.simdOrientation = smoothed!
    }

    /// A white-on-black mask of the Pixel "G" — the ring with a gap on the right and a crossbar
    /// reaching in. Used as a material's transparency mask so only the G shape carries the
    /// metallic finish, the rest of the plane staying clear over the panel.
    private static func pixelGMask(side: Int) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()

        let c = CGFloat(side) / 2
        let outer = CGFloat(side) * 0.46
        let inner = CGFloat(side) * 0.29     // a slightly heavier stroke reads better when engraved
        let center = NSPoint(x: c, y: c)
        NSColor.white.setFill()

        // The ring spans 20°→340° (CCW through the top), leaving a gap on the right; the crossbar
        // fills the lower part of that gap, which is what makes the O read as a G.
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: outer, startAngle: 20, endAngle: 340, clockwise: false)
        ring.appendArc(withCenter: center, radius: inner, startAngle: 340, endAngle: 20, clockwise: true)
        ring.close()
        ring.fill()

        let barHeight = outer - inner
        NSBezierPath(rect: NSRect(x: c, y: c - barHeight / 2,
                                  width: outer - CGFloat(side) * 0.04, height: barHeight)).fill()

        image.unlockFocus()
        return image
    }

    // MARK: - the saved "facing me" reference

    private static let facingMeKey = "TwinFacingMeReference"

    private static func saveFacingMe(_ q: simd_quatf) {
        UserDefaults.standard.set([q.imag.x, q.imag.y, q.imag.z, q.real], forKey: facingMeKey)
    }

    private static func loadFacingMe() -> simd_quatf? {
        guard let v = UserDefaults.standard.array(forKey: facingMeKey) as? [Double], v.count == 4,
              !(v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 0) else { return nil }
        return simd_normalize(simd_quatf(ix: Float(v[0]), iy: Float(v[1]), iz: Float(v[2]), r: Float(v[3])))
    }
}

/// An SCNView that treats R as "re-centre" and hands everything else to the camera controller.
private final class TwinSCNView: SCNView {
    var onRecenter: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            onRecenter?()
        } else {
            super.keyDown(with: event)
        }
    }
}
