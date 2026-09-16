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
//  A foldable is two hinged halves (HeroComposer.makeFoldPhone). The hinge angle comes from the
//  sensor channel and is eased, because the sensor reports in 5° steps; the picture is routed by
//  shape — the inner panel is near-square, the cover panel about half as wide — so when Android
//  moves the stream to the cover the last inner frame stays on the inner glass and the live one
//  lands on the cover. Three render modes, after doc/rplayhub-fold-twin-brief.md, decide how the
//  moving half is textured while it turns: hard cut (as Android draws it), locked (each fragment
//  shows what the camera would see of the flat inner display fixed to the held half — the ground
//  truth, done per fragment in a shader so it is the exact homography), and stylized (the iPhone
//  Duo look: the same projection from a front-on eye fixed to the held half — the eye a phone can
//  assume, since it cannot know where the viewer is — with a blur-and-darken gradient from the
//  crease toward the moving edge). Locked and stylized treat the cover the same way, locking its
//  content to where it lay when shut. Keys 1/2/3 switch them, as does View ▸ Fold Look.
//

import AppKit
import CoreVideo
import Metal
import SceneKit
import simd

final class TwinView: NSView, SCNSceneRendererDelegate {
    /// Pulled once per rendered frame on the render thread; returns the newest device quaternion.
    var orientationSource: (() -> simd_quatf?)?
    /// A foldable's hinge angle in degrees (0 shut, 180 flat), pulled once per frame. Nil when the
    /// device has no hinge sensor, in which case a foldable holds flat.
    var hingeSource: (() -> Float?)?
    /// A foldable's two gyroscopes, rad/s, for attributing the fold to the half that actually
    /// moved. Kept fresh here for the next step; the model currently assumes the held half is
    /// still, as the Linux client does.
    var gyroSource: ((Int) -> simd_float3?)?
    /// A touch on the phone's screen, already mapped to device pixels, with a MotionAction. Wired to
    /// the same injection path the flat viewer uses, so tapping the 3D screen taps the device.
    var onMotion: ((CGPoint, Int32) -> Void)?
    /// The device's canonical (portrait) pixel size — set on activate, used to map a screen hit.
    private var deviceSize: CGSize = .zero

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

    // MARK: fold state

    enum FoldMode: Int, CaseIterable {
        case hardCut = 0, locked = 1, stylized = 2
        var title: String {
            switch self {
            case .hardCut: return "1 Hard cut"
            case .locked: return "2 Locked"
            case .stylized: return "3 Stylized"
            }
        }
    }

    private(set) var foldable = false
    private var pivotNode: SCNNode?
    private var halfANode: SCNNode?
    private var halfBNode: SCNNode?
    private var screenA: SCNMaterial?
    private var screenB: SCNMaterial?
    private var coverMaterial: SCNMaterial?
    private var contentPlaneNode: SCNNode?
    private var coverPlaneNode: SCNNode?
    private var seamA: SCNNode?
    private var seamB: SCNNode?
    private var panelWidth: CGFloat = 0
    private var panelHeight: CGFloat = 0
    private var coverWidth: CGFloat = 0
    private var coverHeight: CGFloat = 0
    private var halfDepth: CGFloat = 0
    private var bezel: CGFloat = 0
    /// The pivot's resting z (the inner glass plane), kept so the fold can slide the model
    /// sideways without disturbing where the hinge sits in depth.
    private var pivotZ: CGFloat = 0
    /// The model's size in scene units, so the camera can be framed to it. A bar phone is about
    /// 0.7 by 1.5; a foldable opens to roughly 1.55 square and needs the camera further back.
    private var modelExtent = CGSize(width: 0.75, height: 1.55)
    private var modelDepth: CGFloat = 0.1
    private var cameraNode: SCNNode?
    private(set) var renderMode: FoldMode = .hardCut
    /// The stylized look's constants, after the iPhone Duo recreation (brief §7): blur radius in
    /// source pixels at the moving edge, the gradient's exponent, where along the half the
    /// darkening starts (0 crease, 1 free edge) and how hard it goes to black, plus the seam
    /// band's width as a fraction of a half — zero, because the Duo's crease stays bright.
    /// Overridable with RPLAYHUB_FOLD_STYLE JSON: {"blur","gamma","dark","gain","w"}.
    private var duoBlur: Float = 72
    private var duoGamma: Float = 1.35
    private var duoDarkStart: Float = 0.2
    private var duoDarkGain: Float = 2
    private var stylizedW: Float = 0
    /// How far the moving half turns to glass mid-fold (`glass · sin φ` of transparency on its
    /// body and both its screens): opaque flat and shut, a frosted pane in between, through
    /// which the held half's content shows.
    private var stylizedGlass: Float = 0.45
    private var halfBMaterials: [SCNMaterial] = []
    /// The readout shows for a few seconds after activation or a mode change, then leaves the
    /// stage clean for a recording.
    private var readoutShownAt: TimeInterval = 0
    private var readoutHidden = false
    // The hinge: what the sensor (or the fake) says, and what is shown after easing.
    private var hingeTarget: Float = 180
    private var hingeShown: Float = 180
    private var haveHinge = false
    private var lastTick: TimeInterval = 0
    private var fakeClock: Double = 0
    private let fakeHinge = ProcessInfo.processInfo.environment["RPLAYHUB_FAKE_HINGE"]
    private var lastLabelUpdate: TimeInterval = 0
    // The fold trace: each new sensor reading and each panel handover goes to the log, so a
    // real sweep leaves evidence (the sensor steps in 5°, so a sweep is a few dozen lines).
    private var lastLoggedHinge: Float = -1
    /// RPLAYHUB_FOLD_DEBUG=1 paints the projected (u, v) on the projected glass, =2 the raw ray.
    private static let debugUV = Float(ProcessInfo.processInfo.environment["RPLAYHUB_FOLD_DEBUG"] ?? "") ?? 0
    private var lastPanelWasInner: Bool?
    // The pictures a fold needs: the newest inner-panel frame and the newest cover-panel frame,
    // each kept with its wrapper so the GPU's copy stays valid after the stream moves on.
    private var lastInner: (wrapper: CVMetalTexture, texture: MTLTexture)?
    private var lastOuter: (wrapper: CVMetalTexture, texture: MTLTexture)?
    /// Inner panel vs cover panel, by shape: a Pixel Fold's inner is ~0.97 wide for its height, the
    /// cover ~0.46. Anything at or above this is the inner panel, so landscape never trips it.
    private static let panelSplitAspect: CGFloat = 0.7

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
        view.onPanelTouch = { [weak self] uv, half, action in self?.handlePanelTouch(uv, half, action) }
        view.onMode = { [weak self] mode in self?.setRenderMode(mode) }
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
        // the face-on default, and it persists that for later sessions. Styled as a clear filled
        // pill — a default rounded button vanishes into the dark 3D scene and reads as plain text.
        recenterButton.title = "Set Facing Me  (R)"
        recenterButton.target = self
        recenterButton.action = #selector(recenterPressed)
        recenterButton.isBordered = false
        recenterButton.wantsLayer = true
        recenterButton.contentTintColor = .white
        recenterButton.font = .systemFont(ofSize: 13, weight: .semibold)
        recenterButton.attributedTitle = NSAttributedString(
            string: "Set Facing Me  (R)",
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        recenterButton.layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.47, blue: 0.95, alpha: 0.95).cgColor
        recenterButton.layer?.cornerRadius = 9
        recenterButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recenterButton)
        NSLayoutConstraint.activate([
            recenterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recenterButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            recenterButton.heightAnchor.constraint(equalToConstant: 34),
            recenterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
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

        // The fold readout, top-left: render mode and hinge angle, only while a foldable is up.
        modeLabel.isEditable = false
        modeLabel.isBordered = false
        modeLabel.drawsBackground = false
        modeLabel.textColor = NSColor(calibratedWhite: 0.9, alpha: 0.9)
        modeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        modeLabel.isHidden = true
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeLabel)
        NSLayoutConstraint.activate([
            modeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            modeLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
        ])

        if let m = ProcessInfo.processInfo.environment["RPLAYHUB_TWIN_MODE"].flatMap(Int.init),
           let mode = FoldMode(rawValue: ((m % 3) + 3) % 3) {
            renderMode = mode
        }
        if let json = ProcessInfo.processInfo.environment["RPLAYHUB_FOLD_STYLE"],
           let data = json.data(using: .utf8),
           let numbers = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            if let v = numbers["blur"] { duoBlur = Float(v) }
            if let v = numbers["gamma"] { duoGamma = Float(v) }
            if let v = numbers["dark"] { duoDarkStart = Float(v) }
            if let v = numbers["gain"] { duoDarkGain = Float(v) }
            if let v = numbers["w"] { stylizedW = Float(v) }
            if let v = numbers["glass"] { stylizedGlass = Float(v) }
        }
    }

    private let hint = NSTextField(labelWithString: "")
    private let recenterButton = NSButton()

    /// The fold on its own: the hinge is the subject, so the phone sits face-on, the rotation
    /// vector is not consulted at all, and there is nothing to orbit or calibrate. This is what
    /// the Linux client's flat fold view is, once the toolkit differences are set aside — and
    /// without the gyro there is no reference pose, so the picture never tilts away from you.
    var foldOnly = false
    private let modeLabel = NSTextField(labelWithString: "")

    // MARK: - mode lifecycle

    /// `displaySize` is the display in its canonical (portrait) orientation; it sets the body's
    /// proportions — rebuilt on each activation because a different device may be mirrored now.
    /// `foldable` builds two hinged halves; nil keeps whatever the last activation chose.
    func activate(displaySize: CGSize, foldable: Bool? = nil) {
        deviceSize = displaySize
        if let foldable { self.foldable = foldable }
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
        // Fold-only strips the twin back to the hinge: no orbit, no calibration, no gyro.
        scnView.allowsCameraControl = !foldOnly
        recenterButton.isHidden = foldOnly
        hint.isHidden = foldOnly || savedFacingMe != nil
        if foldOnly { phoneNode?.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) }
        smoothed = nil
        hingeShown = 180
        hingeTarget = 180
        lastTick = 0
        fakeClock = 0
        modeLabel.isHidden = !self.foldable
        readoutShownAt = 0
        readoutHidden = false
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
        pivotNode = nil
        halfANode = nil
        halfBNode = nil
        screenA = nil
        screenB = nil
        coverMaterial = nil
        contentPlaneNode = nil
        seamA = nil
        seamB = nil
        heldTextures = []
        lastInner = nil
        lastOuter = nil
        modeLabel.isHidden = true
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

    func setRenderMode(_ mode: FoldMode) {
        renderMode = mode
        readoutShownAt = 0
        readoutHidden = false
        AppBuild.log("twin: fold render mode \(mode.title)")
    }

    /// Map a screen-plane hit (texture UV, origin bottom-left) to a canonical device pixel and
    /// forward it. The panel geometry is the physical glass, so this holds at any rotation: touch
    /// coordinates live in the canonical portrait frame regardless of what the screen is showing.
    /// On a foldable each half's plane covers half the glass, so its u is folded into the whole.
    private func handlePanelTouch(_ uv: CGPoint, _ half: Int, _ action: Int32) {
        guard deviceSize.width > 0, deviceSize.height > 0 else { return }
        // The panel's texture UV is top-left origin (v=0 at the top), matching the device's own
        // top-left pixel origin — so both axes map straight through, no flip.
        // Within a half, u runs from its outer edge to the crease for the left half and from
        // the crease outward for the right one. A is the right half now.
        let u = half < 0 ? uv.x : (half == 0 ? 0.5 + uv.x * 0.5 : uv.x * 0.5)
        let x = (u * deviceSize.width).rounded()
        let y = (uv.y * deviceSize.height).rounded()
        onMotion?(CGPoint(x: x, y: y), action)
    }

    @objc private func recenterPressed() {
        recenter()
    }

    // MARK: - the scene

    private func buildScene(displaySize: CGSize) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = Self.studioBackdrop()   // a soft spotlight, premium on camera
        if foldable {
            let built = HeroComposer.makeFoldPhone(displaySize: displaySize, finish: .graphite)
            scene.rootNode.addChildNode(built.node)
            phoneNode = built.node
            pivotNode = built.pivot
            halfANode = built.halfA
            halfBNode = built.halfB
            screenA = built.screenA
            screenB = built.screenB
            coverMaterial = built.cover
            contentPlaneNode = built.contentPlane
            coverPlaneNode = built.coverPlane
            halfBMaterials = built.halfBMaterials
            panelWidth = built.panelWidth
            panelHeight = built.panelHeight
            coverWidth = built.coverWidth
            coverHeight = built.coverHeight
            halfDepth = built.halfDepth
            bezel = built.bezel
            // Open, the two halves span the full inner display plus their bezels.
            modelExtent = CGSize(width: built.panelWidth * 1.06, height: built.panelHeight * 1.06)
            modelDepth = built.halfDepth * 2
            pivotZ = built.halfDepth / 2
            screenMaterial = nil
            // A test grid until the first frame: a fold with nothing on the glass is unreadable,
            // and the grid is what makes the locked mode's mapping across the crease checkable.
            let grid = Self.testGrid(size: displaySize)
            for m in [built.screenA, built.screenB, built.cover] {
                m.diffuse.contents = grid
                m.diffuse.wrapS = .clamp
                m.diffuse.wrapT = .clamp
            }
            // A is the right half of the phone, so it carries the right half of the picture.
            built.screenA.diffuse.contentsTransform = halfTransform(side: 1)
            built.screenB.diffuse.contentsTransform = halfTransform(side: 0)
            built.cover.diffuse.contentsTransform = Self.middleHalfTransform
            // The moving half's inner glass and the cover both carry the projecting shader; off
            // until a mode asks for it.
            for m in [built.screenB, built.cover] {
                m.shaderModifiers = [.surface: Self.projectedSurfaceModifier]
                m.setValue(NSNumber(value: 0), forKey: "project")
            }
            // Seam band: a dark gradient along the crease on each half, scaled with the fold.
            let hd = built.halfDepth / 2
            let (a, b) = Self.makeSeams(panelHeight: built.panelHeight, hd: hd)
            built.halfA.addChildNode(a)
            built.halfB.addChildNode(b)
            seamA = a
            seamB = b
        } else {
            let built = Self.makePhone(displaySize: displaySize)
            scene.rootNode.addChildNode(built.node)
            phoneNode = built.node
            screenMaterial = built.screen
            pivotNode = nil
            let aspect = displaySize.width > 0 && displaySize.height > 0
                ? displaySize.width / displaySize.height : 9.0 / 19.5
            modelExtent = CGSize(width: 1.5 * aspect * 1.06, height: 1.5 * 1.06)
            modelDepth = 1.5 * aspect * 1.06 * 0.116
        }
        addCameraAndLights(scene)
        return scene
    }

    /// The twin wears the same chassis as the hero renderer — one phone, built once in
    /// HeroComposer.makeHeroPhone: two-tone polished rail, bright chamfer, glass, punch hole,
    /// antenna breaks and the buttons on the right rail. What the twin adds is the BACK, because
    /// unlike a hero still the twin turns around: either a user-supplied device photo or the
    /// procedural Pixel back below.
    static func makePhone(displaySize: CGSize) -> (node: SCNNode, screen: SCNMaterial) {
        // A user-supplied back photo replaces the whole back, camera island included.
        let backImage = Self.loadBackImage()
        let built = HeroComposer.makeHeroPhone(displaySize: displaySize, finish: .graphite,
                                               cameraIsland: backImage == nil)
        let phone = built.node
        let screen = built.screen
        let bodyWidth = built.width
        let bodyHeight = built.height
        let bodyDepth = built.depth

        // A user-supplied back image wins: texture it straight onto the back face so the twin
        // wears whatever device the user handed it — a Samsung, a Xiaomi, anything. When one is
        // set the procedural Pixel back (camera bar, lenses, G) is skipped entirely.
        if let backImage {
            let backPlane = SCNPlane(width: bodyWidth, height: bodyHeight)
            let backMat = SCNMaterial()
            backMat.lightingModel = .constant     // show the photo as printed, not relit
            backMat.diffuse.contents = backImage
            backMat.diffuse.wrapS = .clamp
            backMat.diffuse.wrapT = .clamp
            backMat.isDoubleSided = false
            backPlane.materials = [backMat]
            let backNode = SCNNode(geometry: backPlane)
            backNode.position = SCNVector3(0, 0, -bodyDepth / 2 - 0.001)
            backNode.eulerAngles = SCNVector3(0, CGFloat.pi, 0)   // face out the back
            phone.addChildNode(backNode)
            return (phone, screen)
        }

        return (phone, screen)
    }

    /// A radial studio backdrop — a pool of light behind the phone fading to near-black at the
    /// edges. Reads as an intentional stage on camera instead of a flat dark box, and stays dark
    /// (a flat white ground washed the phone out).
    private static func studioBackdrop() -> NSImage {
        let size = NSSize(width: 640, height: 640)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let gradient = NSGradient(colors: [NSColor(calibratedWhite: 0.18, alpha: 1),
                                           NSColor(calibratedWhite: 0.05, alpha: 1)])
        gradient?.draw(in: NSRect(origin: .zero, size: size),
                       relativeCenterPosition: NSPoint(x: 0, y: 0.12))
        img.unlockFocus()
        return img
    }

    private func addCameraAndLights(_ scene: SCNScene) {
        let camera = SCNCamera()
        camera.fieldOfView = 40
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 0, 3.1)
        scene.rootNode.addChildNode(node)
        cameraNode = node
        frameCamera()

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
    }

    /// Pull the camera back just far enough to hold the whole model, on whichever axis is tight.
    /// A fixed distance was chosen for a bar phone, which is narrow: a foldable opens to roughly
    /// square and is then width-bound in this tall stage, so it sat small in the middle of it.
    /// The field of view is vertical, so the horizontal one follows the view's aspect ratio.
    private func frameCamera() {
        guard let cameraNode, let camera = cameraNode.camera else { return }
        let viewAspect = bounds.height > 1 ? bounds.width / bounds.height : 0.75
        let fovY = camera.fieldOfView * .pi / 180
        let tanY = tan(fovY / 2)
        let tanX = tanY * max(viewAspect, 0.1)
        let margin: CGFloat = 1.12                     // a little air around the phone
        let needV = (modelExtent.height / 2) * margin / tanY
        let needH = (modelExtent.width / 2) * margin / tanX
        // Turning the phone swings its corners toward the camera, so leave the depth as clearance.
        cameraNode.position = SCNVector3(0, 0, max(needV, needH) + modelDepth)
    }

    override func layout() {
        super.layout()
        frameCamera()
    }

    // MARK: - fold pieces

    /// The seam band for the stylized mode: a dark gradient along the crease, darkest at the
    /// crease and clear a band-width out, on each half. Scaled with the fold angle each frame.
    private static func makeSeams(panelHeight: CGFloat, hd: CGFloat) -> (SCNNode, SCNNode) {
        func seam(darkOnRight: Bool) -> SCNNode {
            let plane = SCNPlane(width: 1, height: panelHeight)
            // Black, with the gradient's alpha in `transparent` — the channel SceneKit blends
            // by. Alpha in the diffuse image alone is ignored, as the screen masks already know.
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = NSColor.black
            m.transparent.contents = seamImage(darkOnRight: darkOnRight)
            m.transparencyMode = .aOne
            m.transparent.mipFilter = .none
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = false
            plane.materials = [m]
            let n = SCNNode(geometry: plane)
            n.position = SCNVector3(0, 0, hd + 0.006)
            n.scale = SCNVector3(0.0001, 1, 1)
            return n
        }
        // Half A is to the RIGHT of the crease: its band is darkest at its LEFT edge, and B's,
        // to the left of the crease, at its right.
        return (seam(darkOnRight: false), seam(darkOnRight: true))
    }

    private static func seamImage(darkOnRight: Bool) -> NSImage {
        let size = NSSize(width: 256, height: 8)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let g = NSGradient(colors: [NSColor(calibratedWhite: 0, alpha: 0.55), NSColor(calibratedWhite: 0, alpha: 0)])
        g?.draw(in: NSRect(origin: .zero, size: size), angle: darkOnRight ? 180 : 0)
        img.unlockFocus()
        return img
    }

    /// What a foldable's glass shows before any frame arrives, and what the fold rig shows with
    /// no phone: a grid with a big circle across the crease, so continuity of the picture from
    /// the held half to the moving half can be read directly. The crease is the vertical line
    /// through the middle.
    private static func testGrid(size: CGSize) -> NSImage {
        let w = 1024, h = Int((1024 * max(size.height, 1) / max(size.width, 1)).rounded())
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        // A subtle left/right tint, so the two halves are told apart at a glance.
        NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.30, alpha: 1).setFill()
        NSRect(x: w / 2, y: 0, width: w / 2, height: h).fill()
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        let step = 64
        for x in stride(from: 0, through: w, by: step) {
            let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: h)); p.lineWidth = 1; p.stroke()
        }
        for y in stride(from: 0, through: h, by: step) {
            let p = NSBezierPath(); p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: w, y: y)); p.lineWidth = 1; p.stroke()
        }
        // The circle across the crease: at 180° it must be one round circle; in locked mode it
        // must stay round from the camera's seat as the phone folds.
        NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.2, alpha: 0.95).setStroke()
        let r = CGFloat(min(w, h)) * 0.28
        let circle = NSBezierPath(ovalIn: NSRect(x: CGFloat(w) / 2 - r, y: CGFloat(h) / 2 - r, width: 2 * r, height: 2 * r))
        circle.lineWidth = 10
        circle.stroke()
        // A diagonal, for the same reason: a straight line must stay straight in locked mode.
        NSColor(calibratedRed: 0.4, green: 0.9, blue: 1.0, alpha: 0.95).setStroke()
        let diag = NSBezierPath(); diag.move(to: NSPoint(x: 0, y: 0)); diag.line(to: NSPoint(x: w, y: h)); diag.lineWidth = 8; diag.stroke()
        // The crease itself.
        NSColor(calibratedWhite: 1, alpha: 0.6).setFill()
        NSRect(x: w / 2 - 2, y: 0, width: 4, height: h).fill()
        // Labels, so up and left/right are unambiguous.
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 96, weight: .black),
                                                    .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.85)]
        NSAttributedString(string: "L", attributes: attrs).draw(at: NSPoint(x: 40, y: h - 140))
        NSAttributedString(string: "R", attributes: attrs).draw(at: NSPoint(x: w - 110, y: h - 140))
        NSAttributedString(string: "TOP", attributes: attrs).draw(at: NSPoint(x: w / 2 - 110, y: h - 140))
        img.unlockFocus()
        return img
    }

    /// Half `side` (0 left, 1 right) of the picture, then the panel counter-rotation.
    private func halfTransform(side: Int) -> SCNMatrix4 {
        var h = SCNMatrix4Identity
        h.m11 = 0.5
        h.m41 = side == 0 ? 0 : 0.5
        return Self.composed(first: h, then: textureTransform())
    }

    /// The middle half of the inner picture — what the cover shows when no cover frame exists
    /// yet. The cover panel is about half as wide as the inner one and shows the same screen, so
    /// this reads as the content carrying over rather than jumping.
    private static var middleHalfTransform: SCNMatrix4 {
        var h = SCNMatrix4Identity
        h.m11 = 0.5
        h.m41 = 0.25
        return h
    }

    /// Two hand-written texture affines composed (`first` applied, then `second`), written
    /// out element by element. The SCNMatrix4 concatenation helpers were paid for once already
    /// (see textureTransform); this never goes near them.
    /// u' = m11·u + m21·v + m41 ; v' = m12·u + m22·v + m42.
    private static func composed(first a: SCNMatrix4, then b: SCNMatrix4) -> SCNMatrix4 {
        var m = SCNMatrix4Identity
        m.m11 = b.m11 * a.m11 + b.m21 * a.m12
        m.m21 = b.m11 * a.m21 + b.m21 * a.m22
        m.m41 = b.m11 * a.m41 + b.m21 * a.m42 + b.m41
        m.m12 = b.m12 * a.m11 + b.m22 * a.m12
        m.m22 = b.m12 * a.m21 + b.m22 * a.m22
        m.m42 = b.m12 * a.m41 + b.m22 * a.m42 + b.m42
        return m
    }

    /// Locked and stylized modes, per fragment, on the moving half's inner glass and on the
    /// cover. The content plane is the display as it lies with the phone at rest, fixed to the
    /// held half (the flat inner display; the cover as it sits when shut); a fragment on the
    /// moving glass shows whatever an eye would see of that plane through it — the intersection
    /// of the eye→fragment ray with the plane, turned into a texture coordinate. Both are planar,
    /// so this is the exact homography the SurfaceFlinger approximation is trying to reach. In
    /// locked mode the eye is the camera (ground truth); in stylized mode it is a front-on eye
    /// fixed to the held half, which is all a phone can assume. A ray that misses the display
    /// goes black; a plane behind the eye goes black.
    ///
    /// Stylized adds the iPhone Duo treatment (brief §7): along the half, from the crease
    /// (`gradient0`) to the free edge (`gradient1`), a blur whose radius grows as
    /// `blurPx · motion · edge^gamma` and a darkening `1 − min(1, gain · motion · ((edge −
    /// darkStart)/(1 − darkStart))^gamma)`; `motion` is the fold's progress, eased, set per
    /// frame. The blur is a 9×9 binomial tap at a quarter of the radius — the frames have no
    /// mip chain, so the reference's mip-level trick is not available.
    ///
    /// `planeToRef` is the content plane's frame in the eye's space (eye at the origin, columns
    /// x, y, normal, origin); `viewToRef` takes a view-space fragment there (identity when the
    /// eye is the camera). `texXform` is the material's texture affine as a 4×4 on (u, v, 0, 1);
    /// `uOffset` places the plane's origin in u (0.5 for the crease of the inner display, the
    /// projected hinge edge for the cover). `project` switches it all on; `treat` the look.
    private static let projectedSurfaceModifier = """
    #pragma arguments
    float4x4 planeToRef;
    float4x4 viewToRef;
    float4x4 texXform;
    float planeW;
    float planeH;
    float uOffset;
    float gradient0;
    float gradient1;
    float project;
    float treat;
    float motion;
    float blurPx;
    float gammaK;
    float darkStart;
    float darkGain;
    float debugUV;
    #pragma body
    if (project > 0.5) {
        float3 frag = (viewToRef * float4(_surface.position, 1.0)).xyz;
        float3 dir = normalize(frag);
        float3 p0 = planeToRef[3].xyz;
        float3 ax = normalize(planeToRef[0].xyz);
        float3 ay = normalize(planeToRef[1].xyz);
        float3 n = normalize(planeToRef[2].xyz);
        float denom = dot(n, dir);
        float3 color = float3(0.0);
        if (debugUV > 0.5) color = float3(0.3, 0.0, 0.0);   // ray parallel
        if (abs(denom) > 1e-6) {
            float t = dot(n, p0) / denom;
            if (debugUV > 0.5) color = float3(0.0, 0.0, 0.3);   // plane behind
            if (t > 0.0) {
                float3 hit = dir * t - p0;
                float u = dot(hit, ax) / planeW + uOffset;
                float v = 0.5 - dot(hit, ay) / planeH;
                float inside = (u >= 0.0 && u <= 1.0 && v >= 0.0 && v <= 1.0) ? 1.0 : 0.0;
                float2 tuv = (texXform * float4(clamp(u, 0.0, 1.0), clamp(v, 0.0, 1.0), 0.0, 1.0)).xy;
                color = u_diffuseTexture.sample(u_diffuseTextureSampler, tuv).rgb * inside;
                if (debugUV > 1.5) {
                    color = float3(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, fract(t));
                } else if (debugUV > 0.5) {
                    color = float3(fract(u), fract(v), inside);
                } else if (treat > 0.5) {
                    float edge = clamp((u - gradient0) / (gradient1 - gradient0), 0.0, 1.0);
                    float radius = blurPx * motion * pow(edge, gammaK);
                    if (radius > 0.5) {
                        float2 texel = float2(1.0 / float(u_diffuseTexture.get_width()),
                                              1.0 / float(u_diffuseTexture.get_height()));
                        float2 step = texel * radius * 0.25;
                        float3 sum = float3(0.0);
                        for (int y = -4; y <= 4; y++) {
                            int ay_ = abs(y);
                            float wy = ay_ == 0 ? 70.0 : (ay_ == 1 ? 56.0 : (ay_ == 2 ? 28.0 : (ay_ == 3 ? 8.0 : 1.0)));
                            for (int x = -4; x <= 4; x++) {
                                int ax_ = abs(x);
                                float wx = ax_ == 0 ? 70.0 : (ax_ == 1 ? 56.0 : (ax_ == 2 ? 28.0 : (ax_ == 3 ? 8.0 : 1.0)));
                                float2 suv = clamp(tuv + float2(float(x), float(y)) * step, 0.0, 1.0);
                                sum += u_diffuseTexture.sample(u_diffuseTextureSampler, suv).rgb * (wx * wy);
                            }
                        }
                        color = sum / 65536.0 * inside;
                    }
                    float dark = darkGain * motion * pow(clamp((edge - darkStart) / (1.0 - darkStart), 0.0, 1.0), gammaK);
                    color *= 1.0 - min(1.0, dark);
                }
            }
        }
        _surface.diffuse = float4(color, 1.0);
    }
    """

    // MARK: - user-supplied back image

    static let backImageKey = "TwinBackImagePath"

    private static func loadBackImage() -> NSImage? {
        // Only a user-set image overrides the drawn Pixel back. It is used as authored when it
        // already carries transparency, otherwise a light backdrop is cut away.
        guard let path = UserDefaults.standard.string(forKey: backImageKey), !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let raw = NSImage(contentsOfFile: path) else { return nil }
        return hasTransparentBorder(raw) ? raw : removingLightBackground(raw)
    }

    private static func hasTransparentBorder(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return false }
        // The four corners: if any is transparent the image was authored with a cutout already.
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] where buf[(y * w + x) * 4 + 3] < 16 {
            return true
        }
        return false
    }

    /// Clears a light photo backdrop to transparent so the phone sits on the twin's body with no
    /// white plate around it. A flood fill from the borders only removes background connected to
    /// the edge, so a white flash or highlight inside the phone survives.
    private static func removingLightBackground(_ image: NSImage) -> NSImage {
        let w = Int(image.size.width), h = Int(image.size.height)
        guard w > 0, h > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = { () -> UnsafeMutablePointer<UInt8>? in
                  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                  return ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4)
              }() else { return image }

        // A feathered cut. The flood fill spreads through everything lighter than the phone
        // (luminance above `edge`), but the alpha it writes ramps with brightness: fully clear
        // for the bright backdrop, partial through the anti-aliased rim, fading to opaque as it
        // reaches the dark body — so the silhouette gets a smooth edge, not a hard one.
        let edge = 105, solid = 185
        func lum(_ i: Int) -> Int { (Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])) / 3 }
        func alphaFor(_ l: Int) -> UInt8 {
            if l >= solid { return 0 }
            return UInt8(max(0, min(255, 255 * (solid - l) / (solid - edge))))
        }
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func consider(_ p: Int) {
            if visited[p] { return }
            let i = p * 4
            guard lum(i) > edge else { return }       // hit the body; stop, keep it opaque
            visited[p] = true
            buf[i + 3] = alphaFor(lum(i))
            stack.append(p)
        }
        for x in 0..<w { consider(x); consider((h - 1) * w + x) }
        for y in 0..<h { consider(y * w); consider(y * w + w - 1) }
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            if x > 0 { consider(p - 1) }
            if x < w - 1 { consider(p + 1) }
            if y > 0 { consider(p - w) }
            if y < h - 1 { consider(p + w) }
        }
        guard let out = ctx.makeImage() else { return image }
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
    }

    // MARK: - per-frame

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        updateTexture()
        updateOrientation()
        if foldable { updateFold(renderer, time: time) }
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
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, frame, nil, .bgra8Unorm_srgb, width, height, 0, &wrapper)
        guard status == kCVReturnSuccess, let wrapper,
              let texture = CVMetalTextureGetTexture(wrapper) else { return }

        if !foldable {
            heldTextures.append(wrapper)
            if heldTextures.count > 3 { heldTextures.removeFirst() }
            screenMaterial?.diffuse.contents = texture
            screenMaterial?.diffuse.contentsTransform = textureTransform()
            return
        }

        // A foldable: the panels are told apart by shape. When Android folds the phone it turns
        // the inner display off and the stream moves to the cover; the last inner frame stays on
        // the inner glass (which is turning away anyway) and the live one lights the cover.
        // Opening up, the last cover frame is kept so the NEXT fold has something to light the
        // cover with long before Android hands that stream over.
        let isInner = CGFloat(width) / CGFloat(height) >= Self.panelSplitAspect
        if isInner != lastPanelWasInner {
            lastPanelWasInner = isInner
            AppBuild.log(String(format: "fold: stream is now the %@ panel %d×%d at hinge %.0f° (shown %.0f°)",
                                isInner ? "INNER" : "COVER", width, height, hingeTarget, hingeShown))
        }
        if isInner {
            lastInner = (wrapper, texture)
        } else {
            lastOuter = (wrapper, texture)
        }
        if let inner = lastInner {
            screenA?.diffuse.contents = inner.texture
            screenB?.diffuse.contents = inner.texture
        }
        screenA?.diffuse.contentsTransform = halfTransform(side: 1)
        screenB?.diffuse.contentsTransform = halfTransform(side: 0)
        if let outer = lastOuter {
            coverMaterial?.diffuse.contents = outer.texture
            coverMaterial?.diffuse.contentsTransform = SCNMatrix4Identity
        } else if let inner = lastInner {
            coverMaterial?.diffuse.contents = inner.texture
            coverMaterial?.diffuse.contentsTransform = Self.middleHalfTransform
        }
    }

    /// The hinge, eased, and everything that rides on it: the pivot, the locked mode's uniforms,
    /// the stylized mode's alpha ramp and seam band, and the readout.
    private func updateFold(_ renderer: SCNSceneRenderer, time: TimeInterval) {
        let dt = lastTick == 0 ? 1.0 / 60 : min(max(time - lastTick, 0.001), 0.1)
        lastTick = time

        if let fake = fakeHinge {
            // "1" sweeps shut ↔ open; any other number holds that angle, for screenshots.
            fakeClock += dt
            let fixed = Float(fake) ?? 0
            hingeTarget = fixed > 1 ? min(max(fixed, 0), 180) : 90 + 90 * Float(cos(fakeClock * 0.7))
            haveHinge = true
        } else if let h = hingeSource?() {
            hingeTarget = min(max(h, 0), 180)
            haveHinge = true
            if abs(hingeTarget - lastLoggedHinge) >= 1 {
                lastLoggedHinge = hingeTarget
                AppBuild.log(String(format: "fold: hinge %.0f° (shown %.0f°) %@", hingeTarget, hingeShown, renderMode.title))
            }
        } else {
            haveHinge = false
        }
        // The sensor reports in 5° steps ~20 ms apart: ease toward it so the motion reads as one
        // sweep. Without a sensor the same ease is the whole animation, slower.
        let rate: Float = haveHinge ? 30 : 9
        hingeShown += (hingeTarget - hingeShown) * min(1, Float(dt) * rate)
        if abs(hingeTarget - hingeShown) < 0.05 { hingeShown = hingeTarget }
        let phi = (180 - hingeShown) * .pi / 180          // 0 flat, π shut
        // B is the left half, so a POSITIVE turn about y brings its outer edge toward the
        // viewer and over onto A — the way a cover opens off a book whose spine is on the left.
        pivotNode?.eulerAngles = SCNVector3(0, CGFloat(phi), 0)

        // Only one half moves, so the body the eye sees shrinks onto the held half as the phone
        // shuts and would walk off to the right. Slide the model back by half of what the moving
        // half gives up, so a fold happens in place instead of drifting. Open, the shift is zero;
        // shut, it is half a half. Both the held half and the hinge move, so the assembly
        // translates in the phone's own frame and the shift turns with the pose.
        let halfBody = modelExtent.width / 2
        let shift = -halfBody * (1 - max(CGFloat(cos(phi)), 0)) / 2
        halfANode?.position = SCNVector3(shift, 0, 0)
        pivotNode?.position = SCNVector3(shift, 0, pivotZ)

        updateProjection(renderer, phi: phi)

        // Stylized: the moving half turns to glass while it moves. Its body, its inner screen
        // and its cover all take the same transparency; flat and shut it is solid again.
        let glass = renderMode == .stylized ? CGFloat(max(0, min(1, stylizedGlass * sin(phi)))) : 0
        for m in halfBMaterials { m.transparency = 1 - glass }
        screenB?.transparency = 1 - glass
        coverMaterial?.transparency = 1 - glass
        // The seam band widens as the phone closes, and only exists in stylized mode.
        let band = renderMode == .stylized ? CGFloat(stylizedW) * (panelWidth / 2) * CGFloat(min(1, phi)) : 0
        for (seam, sign) in [(seamA, CGFloat(1)), (seamB, CGFloat(-1))] {
            guard let seam else { continue }
            seam.isHidden = band <= 0.0002
            seam.scale = SCNVector3(max(band, 0.0001), 1, 1)
            seam.position = SCNVector3(sign * band / 2, 0, seam.position.z)
        }

        if readoutShownAt == 0 { readoutShownAt = time }
        let hideReadout = time - readoutShownAt > 4
        if time - lastLabelUpdate > 0.1 || hideReadout != readoutHidden {
            lastLabelUpdate = time
            readoutHidden = hideReadout
            let text = String(format: "%@   hinge %.0f°   (View ▸ Fold Look, or 1/2/3)", renderMode.title, hingeShown)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.modeLabel.stringValue = text
                self.modeLabel.isHidden = !self.foldable || hideReadout
            }
        }
    }

    /// Locked and stylized: hand the shader each content plane in the eye's space. Both nodes'
    /// presentation transforms are what is on screen this frame. The eye is the camera (wherever
    /// the orbit left it) in locked mode, and in stylized mode a front-on eye fixed to the held
    /// half at the camera's distance — in Fold View the two coincide.
    private func updateProjection(_ renderer: SCNSceneRenderer, phi: Float) {
        guard let screenB, let coverMaterial else { return }
        let project = renderMode != .hardCut
        screenB.setValue(NSNumber(value: project ? 1 : 0), forKey: "project")
        coverMaterial.setValue(NSNumber(value: project ? 1 : 0), forKey: "project")
        guard project, let pov = renderer.pointOfView, let inner = contentPlaneNode,
              let coverPlane = coverPlaneNode, let phone = phoneNode, let halfB = halfBNode else { return }

        let camera = pov.presentation.simdWorldTransform
        let stylized = renderMode == .stylized
        var eye = camera
        if stylized {
            var ahead = matrix_identity_float4x4
            ahead.columns.3 = SIMD4<Float>(0, 0, Float(cameraNode?.position.z ?? 3.1), 1)
            eye = phone.presentation.simdWorldTransform * ahead
        }
        let eyeInverse = simd_inverse(eye)
        let viewToRef = NSValue(scnMatrix4: SCNMatrix4(eyeInverse * camera))

        // The fold's progress, eased the way the reference does: the inner glass is untouched
        // flat and fully treated by 90° and beyond; the cover is untouched shut and fully treated
        // by 90° and beyond.
        func motion(_ p: Float) -> Float { let c = min(max(p, 0), 1); return c * c * (3 - 2 * c) }
        let halfTurn = Float.pi / 2

        let innerToRef = eyeInverse * inner.presentation.simdWorldTransform
        screenB.setValue(NSValue(scnMatrix4: SCNMatrix4(innerToRef)), forKey: "planeToRef")
        screenB.setValue(viewToRef, forKey: "viewToRef")
        screenB.setValue(NSValue(scnMatrix4: textureTransform()), forKey: "texXform")
        screenB.setValue(NSNumber(value: Float(panelWidth)), forKey: "planeW")
        screenB.setValue(NSNumber(value: Float(panelHeight)), forKey: "planeH")
        screenB.setValue(NSNumber(value: 0.5), forKey: "uOffset")
        screenB.setValue(NSNumber(value: 0.5), forKey: "gradient0")
        screenB.setValue(NSNumber(value: 0), forKey: "gradient1")
        screenB.setValue(NSNumber(value: motion(phi / halfTurn)), forKey: "motion")

        // The cover's content is anchored at its hinge-side edge: wherever that edge projects
        // onto the shut-cover plane this frame is u = 0, so the picture stays attached to the
        // hinge while the free edge lifts away and foreshortens.
        let coverToRef = eyeInverse * coverPlane.presentation.simdWorldTransform
        let hingeEdgeLocal = SIMD4<Float>(Float(-bezel), 0, Float(-halfDepth / 2 - 0.003), 1)
        let hingeEdgeRef = (eyeInverse * halfB.presentation.simdWorldTransform * hingeEdgeLocal)
        let anchorU = Self.planeU(of: SIMD3(hingeEdgeRef.x, hingeEdgeRef.y, hingeEdgeRef.z),
                                  planeToRef: coverToRef, width: Float(coverWidth)) ?? 0
        coverMaterial.setValue(NSValue(scnMatrix4: SCNMatrix4(coverToRef)), forKey: "planeToRef")
        coverMaterial.setValue(viewToRef, forKey: "viewToRef")
        coverMaterial.setValue(NSValue(scnMatrix4: coverMaterial.diffuse.contentsTransform), forKey: "texXform")
        coverMaterial.setValue(NSNumber(value: Float(coverWidth)), forKey: "planeW")
        coverMaterial.setValue(NSNumber(value: Float(coverHeight)), forKey: "planeH")
        coverMaterial.setValue(NSNumber(value: -anchorU), forKey: "uOffset")
        coverMaterial.setValue(NSNumber(value: 0), forKey: "gradient0")
        coverMaterial.setValue(NSNumber(value: 1), forKey: "gradient1")
        coverMaterial.setValue(NSNumber(value: motion((Float.pi - phi) / halfTurn)), forKey: "motion")

        for m in [screenB, coverMaterial] {
            m.setValue(NSNumber(value: stylized ? 1 : 0), forKey: "treat")
            m.setValue(NSNumber(value: duoBlur), forKey: "blurPx")
            m.setValue(NSNumber(value: duoGamma), forKey: "gammaK")
            m.setValue(NSNumber(value: duoDarkStart), forKey: "darkStart")
            m.setValue(NSNumber(value: duoDarkGain), forKey: "darkGain")
            m.setValue(NSNumber(value: Self.debugUV), forKey: "debugUV")
        }
    }

    /// Where the ray from the eye (at the origin) through `point` meets the plane, as a fraction
    /// of the plane's width from its origin; nil when the ray misses or the plane is behind.
    private static func planeU(of point: SIMD3<Float>, planeToRef: simd_float4x4, width: Float) -> Float? {
        let dir = simd_normalize(point)
        let p0 = SIMD3(planeToRef.columns.3.x, planeToRef.columns.3.y, planeToRef.columns.3.z)
        let ax = simd_normalize(SIMD3(planeToRef.columns.0.x, planeToRef.columns.0.y, planeToRef.columns.0.z))
        let n = simd_normalize(SIMD3(planeToRef.columns.2.x, planeToRef.columns.2.y, planeToRef.columns.2.z))
        let denom = simd_dot(n, dir)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(n, p0) / denom
        guard t > 0 else { return nil }
        return simd_dot(dir * t - p0, ax) / width
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
        return Self.panelTransform(quadrants: quadrants)
    }

    /// The counter-rotation for a picture arriving `quadrants` quarter-turns from the panel's
    /// own orientation. Shared with the hero renderer, which paints the same frames.
    static func panelTransform(quadrants: Int) -> SCNMatrix4 {
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
        // Fold-only: the phone holds face-on and only the hinge moves.
        if foldOnly { return }
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
        // The delta MUST be taken in the phone's own body frame — ref⁻¹ · q, not q · ref⁻¹. The
        // world-frame form smears a pure tilt across yaw whenever the "facing me" pose is itself
        // tilted (a handheld pose always is), which is the "pitch toward me also twists left/right"
        // symptom. And no world→SceneKit remap is needed: the twin's face-on pose already aligns
        // its axes with the phone's screen axes (x right, y up/top, z out toward the viewer), so
        // the body delta drives the node directly. Conjugating through a remap is what mixed axes.
        let ref = reference ?? q
        let target = ref.inverse * q

        // Adaptive smoothing, so accuracy does not fight latency. A fixed slerp is a bad
        // compromise: gentle enough to kill the small jitter of a still phone, it visibly lags a
        // fast turn; snappy enough to track a fast turn, it shivers when still. Instead the blend
        // scales with how far the pose moved this frame — near-still frames get heavy smoothing,
        // fast frames get almost none — which reads as both steady and immediate.
        if let s = smoothed {
            let dot = min(1, abs(simd_dot(s.vector, target.vector)))
            let stepDegrees = Float(2 * acos(dot) * 180 / .pi)   // angle between s and target
            // A deadband kills the shiver of a phone lying still: the rotation-vector sensor
            // dithers a few tenths of a degree frame to frame even when nothing moves, and a
            // 0.18 floor let that through at 50 Hz as a visible wobble. Below ~0.35 deg the pose
            // is treated as unchanged and barely blended; above it the old adaptive ramp takes
            // over, so a real turn is still immediate.
            let alpha: Float
            if stepDegrees < 0.35 {
                alpha = 0.02
            } else {
                alpha = simd_clamp(0.10 + stepDegrees * 0.30, 0.10, 0.9)
            }
            smoothed = simd_slerp(s, target, alpha)
        } else {
            smoothed = target
        }
        phoneNode?.simdOrientation = smoothed!
    }

    /// The Google "G" as the Pixel wears it, drawn subtly-dark on a transparent field. The mark
    /// is a ring with its opening in the upper-right and a crossbar reaching in from the middle
    /// of the right edge to the centre — that asymmetry (gap above, bar at the middle) is what
    /// makes it read as a G rather than a power symbol.
    static func googleGImage(side: Int) -> NSImage {
        let s = CGFloat(side)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let c = s / 2
        let center = NSPoint(x: c, y: c)
        let outer = s * 0.42
        let inner = s * 0.27
        let stroke = outer - inner
        NSColor(calibratedWhite: 0.26, alpha: 1).setFill()   // subtly darker than the body

        // Ring with a small gap in the upper-right. Its right side runs down to ~10° — level with
        // the top of the raised bar — so the two merge with no notch; the arc spans 62°
        // counter-clockwise round to 370° (= 10°), leaving 10°–62° open.
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: outer, startAngle: 62, endAngle: 370, clockwise: false)
        ring.appendArc(withCenter: center, radius: inner, startAngle: 370, endAngle: 62, clockwise: true)
        ring.close()
        ring.fill()

        // The crossbar: centred on the middle (top a half-stroke above centre, level with where the
        // arc comes down), from the centre out to the ring, where it merges into the arc.
        NSBezierPath(rect: NSRect(x: c, y: c - stroke / 2, width: inner + stroke * 0.3, height: stroke)).fill()

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

/// An SCNView that treats R as "re-centre", 1/2/3 as the fold render modes, turns a click on the
/// phone's screen into a touch, and hands everything else (a drag on empty space) to the camera
/// controller to orbit.
private final class TwinSCNView: SCNView {
    var onRecenter: (() -> Void)?
    var onMode: ((TwinView.FoldMode) -> Void)?
    /// (texture UV, half, MotionAction) when the click lands on the screen; half is -1 for the
    /// rigid phone's single panel, 0 and 1 for a foldable's. A nil hit falls through to orbit.
    var onPanelTouch: ((CGPoint, Int, Int32) -> Void)?

    private var touching = false
    private var last: (CGPoint, Int)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r": onRecenter?()
        case "1": onMode?(.hardCut)
        case "2": onMode?(.locked)
        case "3": onMode?(.stylized)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = panelUV(for: event) {
            touching = true
            last = hit
            onPanelTouch?(hit.0, hit.1, MotionAction.down)
        } else {
            touching = false
            super.mouseDown(with: event)          // empty space — orbit the camera
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching else { super.mouseDragged(with: event); return }
        if let hit = panelUV(for: event) {
            last = hit
            onPanelTouch?(hit.0, hit.1, MotionAction.move)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard touching else { super.mouseUp(with: event); return }
        if let hit = panelUV(for: event) ?? last {
            onPanelTouch?(hit.0, hit.1, MotionAction.up)     // a drag off the screen still has to release
        }
        touching = false
    }

    /// The screen plane's texture UV under the pointer and which panel it is, or nil if the
    /// screen is not the nearest surface there — so you can only tap the screen while it faces
    /// you, and a click on the body or the empty stage orbits instead.
    private func panelUV(for event: NSEvent) -> (CGPoint, Int)? {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = hitTest(p, options: nil).first else { return nil }
        let half: Int
        switch hit.node.name {
        case "panel": half = -1
        case "panelA": half = 0
        case "panelB": half = 1
        default: return nil
        }
        let tc = hit.textureCoordinates(withMappingChannel: 0)
        return (CGPoint(x: tc.x, y: tc.y), half)
    }
}
