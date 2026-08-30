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
    private var yawCorrection: simd_quatf?
    private var reference: simd_quatf?
    private var smoothed: simd_quatf?
    private var recenterRequested = true

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

        let recenterButton = NSButton(title: "Re-centre  (R)", target: self,
                                      action: #selector(recenterPressed))
        recenterButton.bezelStyle = .rounded
        recenterButton.controlSize = .small
        recenterButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recenterButton)
        NSLayoutConstraint.activate([
            recenterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recenterButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - mode lifecycle

    /// `displaySize` is the display in its canonical (portrait) orientation; it sets the body's
    /// proportions — rebuilt on each activation because a different device may be mirrored now.
    func activate(displaySize: CGSize) {
        scnView.scene = buildScene(displaySize: displaySize)
        scnView.rendersContinuously = true       // orientation changes without scene mutations
        recenterRequested = true
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
            yawCorrection = Self.yawCorrection(for: q)
            reference = yawCorrection! * q
            smoothed = nil
            recenterRequested = false
        }
        // Re-centre is a calibration: hold the phone parallel to the Mac's screen, press R, and
        // that pose becomes the twin's face-on. What renders afterwards is the *delta* from that
        // reference, taken in the world frame with the heading corrected so the viewer sits
        // where the screen pointed at re-centre — which is what keeps directions true: turning
        // the phone left turns the twin left, tilting the top toward you brings it toward you,
        // and coming back parallel to the Mac screen brings the twin back flat.
        //
        // Android's rotation vector maps the device frame into an East-North-Up world: x east,
        // y north, z sky. SceneKit's world is x right, y up, z toward the viewer. Rotating the
        // world -90° about x maps one onto the other (E→x, U→y, N→away); the delta is conjugated
        // through that map to act about SceneKit's axes.
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let corrected = (yawCorrection ?? identity) * q
        let delta = corrected * (reference ?? corrected).inverse
        let worldFix = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        let target = worldFix * delta * worldFix.inverse
        let next = smoothed.map { simd_slerp($0, target, 0.35) } ?? target
        smoothed = next
        phoneNode?.simdOrientation = next
    }

    /// The pure world-vertical rotation that brings the phone's current heading to the viewer,
    /// in ENU coordinates. For an upright-ish phone, the screen normal is the heading and should
    /// point South — with East-North-Up mapped so the viewer looks North, South is toward them.
    /// For a flat phone the normal is vertical and carries no heading, so the top edge stands
    /// in, pointing North — lying on the desk with its top away, as a phone in front of you does.
    private static func yawCorrection(for q: simd_quatf) -> simd_quatf {
        let normal = q.act(simd_float3(0, 0, 1))
        let top = q.act(simd_float3(0, 1, 0))
        let normalIsHorizontal = normal.x * normal.x + normal.y * normal.y > 0.09
        let (east, north, targetAzimuth): (Float, Float, Float) = normalIsHorizontal
            ? (normal.x, normal.y, .pi)   // South
            : (top.x, top.y, 0)           // North
        // Azimuth measured from North toward East; a rotation of θ about the vertical moves a
        // vector's azimuth by -θ, so turning `azimuth` into `targetAzimuth` takes their difference.
        let azimuth = atan2f(east, north)
        return simd_quatf(angle: azimuth - targetAzimuth, axis: simd_float3(0, 0, 1))
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
