//
//  HeroComposer.swift
//  Store-listing "hero" renders of the live mirror: the phone at a tilt on a dark gradient with a
//  headline and a brand badge, the way YouTube Studio's Play Store and App Store pages present it.
//
//  Three passes into one bitmap: a 2D gradient, an offscreen SceneKit render of a phone built for
//  the camera (makeHeroPhone: polished metal body, black glass, the live frame on the screen), and
//  vector typography on top. The same composer paints a still (PNG at store sizes) and every frame of a recording
//  (HeroPanel drives it at 30 fps into a FrameRecorder), so a video is exactly the screenshot in
//  motion.
//
//  Frames arrive as CVPixelBuffers in whatever format the decoder is in (YCbCr normally, BGRA
//  while the twin is up); Core Image turns either into a CGImage for the panel material, which
//  keeps orientation obvious — an image lands on the panel upright with an identity transform,
//  the quadrant counter-rotation from the packet header is applied the same way the twin does.
//

import AppKit
import CoreImage
import CoreVideo
import ImageIO
import SceneKit
import UniformTypeIdentifiers

/// One output size. Store sizes as Google and Apple list them; "Video" is a recording target.
struct HeroSize: Equatable {
    let platform: String     // "Google Play", "App Store", "Video"
    let label: String
    let width: Int
    let height: Int

    var size: CGSize { CGSize(width: width, height: height) }
    var title: String { "\(platform) · \(label)  \(width)×\(height)" }
    var filename: String {
        let slug = "\(platform) \(label)".lowercased()
            .replacingOccurrences(of: "″", with: "in")
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(slug)-\(width)x\(height)"
    }

    static let all: [HeroSize] = [
        HeroSize(platform: "Google Play", label: "Phone", width: 1080, height: 1920),
        HeroSize(platform: "Google Play", label: "Phone 20:9", width: 1080, height: 2400),
        HeroSize(platform: "Google Play", label: "Phone QHD", width: 1440, height: 2560),
        HeroSize(platform: "App Store", label: "6.9″", width: 1320, height: 2868),
        HeroSize(platform: "App Store", label: "6.7″", width: 1290, height: 2796),
        HeroSize(platform: "App Store", label: "6.5″", width: 1242, height: 2688),
        HeroSize(platform: "Video", label: "1080p portrait", width: 1080, height: 1920),
        HeroSize(platform: "Video", label: "4K portrait", width: 2160, height: 3840),
    ]
}

/// A chassis finish: the polished rail, the matte face, and the chamfer that carries the
/// highlight. Keeping them separate is what gives the edge its two-tone read.
enum HeroFinish: String, Codable, CaseIterable {
    case graphite, midnight, sand, silver

    var title: String {
        switch self {
        case .graphite: return "Graphite"
        case .midnight: return "Midnight Blue"
        case .sand: return "Desert Sand"
        case .silver: return "Silver"
        }
    }
    var rail: NSColor {
        switch self {
        case .graphite: return NSColor(srgbRed: 0.42, green: 0.43, blue: 0.46, alpha: 1)
        case .midnight: return NSColor(srgbRed: 0.16, green: 0.26, blue: 0.62, alpha: 1)
        case .sand:     return NSColor(srgbRed: 0.78, green: 0.58, blue: 0.40, alpha: 1)
        case .silver:   return NSColor(srgbRed: 0.80, green: 0.82, blue: 0.85, alpha: 1)
        }
    }
    var body: NSColor {
        switch self {
        case .graphite: return NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1)
        case .midnight: return NSColor(srgbRed: 0.07, green: 0.09, blue: 0.18, alpha: 1)
        case .sand:     return NSColor(srgbRed: 0.34, green: 0.27, blue: 0.21, alpha: 1)
        case .silver:   return NSColor(srgbRed: 0.62, green: 0.64, blue: 0.67, alpha: 1)
        }
    }
    /// A touch brighter than the rail: the chamfer is the first thing the light finds.
    var chamfer: NSColor {
        rail.blended(withFraction: 0.34, of: .white) ?? rail
    }
}

/// Everything about the look that is not the picture. Persisted as JSON in UserDefaults.
struct HeroStyle: Codable, Equatable {
    var headline = "Your\ncreative"
    var accentLine = "partner"
    var accent = RGBA(r: 0.80, g: 0.72, b: 0.94, a: 1)      // lavender, as Studio's
    var brand = "rPlayHub"
    var gradientTop = RGBA(r: 0.086, g: 0.086, b: 0.094, a: 1)
    var gradientMid = RGBA(r: 0.118, g: 0.102, b: 0.157, a: 1)
    var gradientBottom = RGBA(r: 0.290, g: 0.220, b: 0.470, a: 1)
    /// The hero pose, degrees. Roll leans the phone; yaw turns its right edge away.
    var pitch: Double = 6
    var yaw: Double = -22
    var roll: Double = 14
    /// Body height as a fraction of the frame height — over 1 clips the phone, on purpose.
    var scale: Double = 0.88
    /// Where the phone's centre sits, as fractions of the frame from its centre (x right, y up).
    var offsetX: Double = 0.20
    var offsetY: Double = -0.26
    var fieldOfView: Double = 30
    var showBadge = true
    var shadow = true
    var finish: HeroFinish = .graphite

    struct RGBA: Codable, Equatable {
        var r: Double, g: Double, b: Double, a: Double
        var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var cgColor: CGColor { color.cgColor }
        init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? color
            r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
        }
    }

    static let defaultsKey = "HeroStyle2"

    static func load() -> HeroStyle {
        var style = HeroStyle()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(HeroStyle.self, from: data) {
            style = saved
        }
        // Dev hook: RPLAYHUB_HERO_STYLE='{"scale":0.9,"roll":14}' overrides the pose numbers
        // for a run, so a look can be dialled in without rebuilding.
        if let json = ProcessInfo.processInfo.environment["RPLAYHUB_HERO_STYLE"],
           let data = json.data(using: .utf8),
           let numbers = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            for (key, value) in numbers {
                switch key {
                case "pitch": style.pitch = value
                case "yaw": style.yaw = value
                case "roll": style.roll = value
                case "scale": style.scale = value
                case "offsetX": style.offsetX = value
                case "offsetY": style.offsetY = value
                case "fieldOfView": style.fieldOfView = value
                default: break
                }
            }
        }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Renders hero frames. Not thread-safe by itself: HeroPanel funnels every call through one
/// serial queue, because SceneKit wants a scene touched from a single thread at a time.
final class HeroComposer {
    private(set) var displaySize: CGSize
    private(set) var finish: HeroFinish
    private let scene = SCNScene()
    private let phone: SCNNode
    private let screen: SCNMaterial
    private let cameraNode = SCNNode()
    private let renderer: SCNRenderer
    private let ciContext: CIContext
    private var quadrants = 0
    private var lastImage: CGImage?

    /// The body's height and width in scene units, from makeHeroPhone.
    private let bodyHeight: CGFloat
    private let bodyWidth: CGFloat

    init(displaySize: CGSize, finish: HeroFinish = .graphite) {
        self.displaySize = displaySize
        self.finish = finish
        let device = MTLCreateSystemDefaultDevice()
        renderer = SCNRenderer(device: device, options: nil)
        ciContext = device.map { CIContext(mtlDevice: $0) } ?? CIContext()

        let built = Self.makeHeroPhone(displaySize: displaySize, finish: finish)
        phone = built.node
        screen = built.screen
        bodyHeight = built.height
        bodyWidth = built.width
        scene.rootNode.addChildNode(phone)
        scene.background.contents = nil          // transparent: the gradient is drawn underneath
        // A studio environment for the metal to reflect: bright above, dark below, one hot
        // band — that is what draws the highlight line along a rounded rail.
        scene.lightingEnvironment.contents = Self.studioEnvironment()
        scene.lightingEnvironment.intensity = 1.7

        let camera = SCNCamera()
        camera.projectionDirection = .vertical
        camera.zNear = 0.05
        camera.zFar = 50
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        // The twin's lighting, so the body reads the same in both places.
        // Deliberately dim. Under physically based shading the environment supplies the
        // specular — the rim line, the lens glints — and these lights only add diffuse. At the
        // old intensities they lifted a near-black graphite back to a flat mid grey that read
        // as plastic. doc/pixel-backside.png is the target: charcoal, not silver.
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 260
        key.eulerAngles = SCNVector3(-0.5, 0.4, 0)
        scene.rootNode.addChildNode(key)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 70
        scene.rootNode.addChildNode(ambient)
        // A rim light from the upper left, raking the side that faces the camera once the phone
        // turns, so the rail catches a highlight instead of vanishing into the background.
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 320
        rim.eulerAngles = SCNVector3(-0.3, -1.1, 0)
        scene.rootNode.addChildNode(rim)
        // A second, harder light from high on the left, aimed at the phone: it catches only the
        // bevel between glass and rail, the razor-thin bright line the reference has.
        let bevel = SCNNode()
        bevel.light = SCNLight()
        bevel.light!.type = .directional
        bevel.light!.intensity = 520
        bevel.position = SCNVector3(-2.0, 3.0, 1.5)
        bevel.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(bevel)

        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
    }

    /// How many quarter-turns the arriving picture is rotated relative to the panel.
    func setQuadrants(_ q: Int) { quadrants = q }

    /// Paint a decoded frame onto the panel. Any CoreVideo format the decoder produces.
    func setFrame(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        lastImage = cg
        screen.diffuse.contents = cg
        screen.diffuse.contentsTransform = TwinView.panelTransform(quadrants: quadrants)
    }

    var hasFrame: Bool { lastImage != nil }

    /// A pose override for animation; nil renders the style's own.
    struct Pose {
        var pitch: Double, yaw: Double, roll: Double
    }

    /// One finished hero frame at `size`. `supersample` renders the phone at twice the size and
    /// scales it down — cleaner edges for a still; a recording keeps 1x to hold its frame rate.
    func render(size: CGSize, style: HeroStyle, pose: Pose? = nil, supersample: Bool = true) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        drawGradient(in: context, bounds: bounds, style: style)
        let renderSize = supersample ? CGSize(width: size.width * 2, height: size.height * 2) : size
        if let phoneImage = renderPhone(size: renderSize, style: style, pose: pose) {
            context.interpolationQuality = .high
            if style.shadow, let shadow = shadowImage(of: phoneImage, scale: renderSize.width / 1080) {
                // Down and to the left, as the reference casts it: the phone stops floating.
                let k = bounds.width / 1080
                context.draw(shadow, in: bounds.offsetBy(dx: -35 * k, dy: -45 * k))
            }
            context.draw(phoneImage, in: bounds)
        }
        drawTypography(in: context, bounds: bounds, style: style)
        return context.makeImage()
    }

    // MARK: - passes

    private func drawGradient(in context: CGContext, bounds: CGRect, style: HeroStyle) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Near-black at the top easing into the purple pool at the bottom, as the reference.
        let colors = [style.gradientTop.cgColor, style.gradientMid.cgColor, style.gradientBottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.maxY),
                                       end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
        }
        // A soft glow low on the left, so the bottom is a pool of light rather than a flat wash.
        let glow = style.gradientBottom
        let glowColors = [CGColor(srgbRed: min(glow.r + 0.12, 1), green: min(glow.g + 0.10, 1),
                                  blue: min(glow.b + 0.14, 1), alpha: 0.55),
                          CGColor(srgbRed: glow.r, green: glow.g, blue: glow.b, alpha: 0)] as CFArray
        if let radial = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1]) {
            let center = CGPoint(x: bounds.width * 0.25, y: bounds.height * 0.12)
            context.drawRadialGradient(radial, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: bounds.width * 0.9, options: [])
        }
    }

    private func renderPhone(size: CGSize, style: HeroStyle, pose: Pose?) -> CGImage? {
        let p = pose ?? Pose(pitch: style.pitch, yaw: style.yaw, roll: style.roll)
        let rad = CGFloat.pi / 180
        phone.eulerAngles = SCNVector3(CGFloat(p.pitch) * rad, CGFloat(p.yaw) * rad, CGFloat(p.roll) * rad)

        // Place the camera so the body spans `scale` of the frame height, then slide the phone
        // by the offsets measured in visible frame units at its depth.
        let fov = CGFloat(style.fieldOfView) * rad
        // A phone stands taller than it is wide; a landscape display (a car head unit) is the
        // other way round, so frame by whichever side of the body is longer.
        let bodyExtent = max(bodyHeight, bodyWidth)
        let visibleHeight = bodyExtent / max(CGFloat(style.scale), 0.05)
        let distance = visibleHeight / (2 * tan(fov / 2))
        let visibleWidth = visibleHeight * size.width / size.height
        cameraNode.camera?.fieldOfView = CGFloat(style.fieldOfView)
        cameraNode.position = SCNVector3(0, 0, distance)
        phone.position = SCNVector3(CGFloat(style.offsetX) * visibleWidth,
                                    CGFloat(style.offsetY) * visibleHeight, 0)

        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func drawTypography(in context: CGContext, bounds: CGRect, style: HeroStyle) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let scale = bounds.width / 1080
        let margin = 88 * scale

        // Headline: heavy, tight leading, white; the accent line in the brand colour.
        let fontSize = 172 * scale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = -fontSize * 0.10
        paragraph.maximumLineHeight = fontSize * 1.02
        paragraph.minimumLineHeight = fontSize * 1.02
        let text = NSMutableAttributedString()
        let headline = style.headline.trimmingCharacters(in: .newlines)
        if !headline.isEmpty {
            text.append(NSAttributedString(string: headline, attributes: [
                .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .kern: -fontSize * 0.03]))
        }
        if !style.accentLine.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph])) }
            text.append(NSAttributedString(string: style.accentLine, attributes: [
                .font: font, .foregroundColor: style.accent.color, .paragraphStyle: paragraph, .kern: -fontSize * 0.03]))
        }
        let textHeight = ceil(text.boundingRect(with: CGSize(width: bounds.width - margin, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin]).height)
        let textTop = bounds.maxY - 110 * scale
        text.draw(with: CGRect(x: margin, y: textTop - textHeight, width: bounds.width - margin, height: textHeight),
                  options: [.usesLineFragmentOrigin])

        guard style.showBadge, !style.brand.isEmpty else { return }

        // Brand badge, bottom-left: a white play pill and the name in a condensed bold.
        let badgeY = 118 * scale
        let pillW = 112 * scale, pillH = 78 * scale
        let pill = NSBezierPath(roundedRect: CGRect(x: margin, y: badgeY, width: pillW, height: pillH),
                                xRadius: pillH * 0.32, yRadius: pillH * 0.32)
        NSColor.white.setFill()
        pill.fill()
        let tri = NSBezierPath()
        let cx = margin + pillW / 2, cy = badgeY + pillH / 2, th = pillH * 0.42
        tri.move(to: CGPoint(x: cx - th * 0.45, y: cy + th / 2))
        tri.line(to: CGPoint(x: cx + th * 0.55, y: cy))
        tri.line(to: CGPoint(x: cx - th * 0.45, y: cy - th / 2))
        tri.close()
        style.gradientBottom.color.blended(withFraction: 0.5, of: .black)?.setFill()
        tri.fill()

        let brandSize = 86 * scale
        let base = NSFont.systemFont(ofSize: brandSize, weight: .bold)
        let condensed = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.condensed), size: brandSize) ?? base
        let brand = NSAttributedString(string: style.brand, attributes: [
            .font: condensed, .foregroundColor: NSColor.white])
        let brandRect = CGRect(x: margin + pillW + 26 * scale, y: badgeY + (pillH - brandSize * 1.15) / 2,
                               width: bounds.width - margin * 2 - pillW, height: brandSize * 1.25)
        brand.draw(with: brandRect, options: [.usesLineFragmentOrigin])
    }

    // MARK: - the hero phone

    /// A phone built for the camera rather than for turning in the hand: an extruded
    /// rounded-rectangle body in polished graphite (physically based, so the environment draws a
    /// highlight along every rounded edge), a black glass front, the screen inset with rounded
    /// corners, the punch hole, and the side buttons on the rail that faces the viewer.
    static func makeHeroPhone(displaySize: CGSize, finish: HeroFinish = .graphite,
                              cameraIsland: Bool = true)
        -> (node: SCNNode, screen: SCNMaterial, width: CGFloat, height: CGFloat, depth: CGFloat) {
        let aspect = displaySize.width > 0 && displaySize.height > 0
            ? displaySize.width / displaySize.height : 9.0 / 19.5
        let panelHeight: CGFloat = 1.5
        let panelWidth = panelHeight * aspect
        let bezel = panelWidth * 0.028                  // the black glass border around the picture
        let bodyWidth = panelWidth + 2 * bezel
        let bodyHeight = panelHeight + 2 * bezel
        // Real hardware: a Pixel 9 is 8.5 mm thick and 72 mm wide, so thickness over width is
        // about 0.118, and every current phone lands near that. We were at 0.068, barely half,
        // which is why the rail read as a thin line rather than a rail.
        let depth = bodyWidth * 0.116
        let corner = bodyWidth * 0.115                  // the plan-view corner radius

        let phone = SCNNode()

        // Body: rounded rectangle extruded to the phone's thickness, with a soft chamfer so the
        // edge between face and rail is a curve that can carry a highlight.
        let bodyPath = NSBezierPath(roundedRect: NSRect(x: -bodyWidth / 2, y: -bodyHeight / 2,
                                                        width: bodyWidth, height: bodyHeight),
                                    xRadius: corner, yRadius: corner)
        bodyPath.flatness = 0.0005
        let body = SCNShape(path: bodyPath, extrusionDepth: depth)
        body.chamferMode = .both
        body.chamferRadius = depth * 0.26
        // Two-tone, which is the thing that makes a real phone's edge read: the RAIL is a
        // brighter, more saturated, more polished metal than the faces around it, so the eye
        // catches a bright band with a hard line down each side. One uniform grey cannot do it,
        // however good the lighting is. SCNShape takes its materials as front, back, side, then
        // the two chamfer profiles, so each gets its own.
        func pbr(_ color: NSColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            return m
        }
        let rail = pbr(finish.rail, metalness: 0.98, roughness: 0.08)      // polished band
        // The back is glass, not metal. Their model makes the same call: dark base, low
        // metalness, mid roughness. At 0.55 metalness ours drank the environment and came out
        // a flat light grey that read as plastic.
        let face = pbr(finish.body, metalness: 0.15, roughness: 0.55)      // matte glass back
        let edge = pbr(finish.chamfer, metalness: 1.0, roughness: 0.04)    // the bright line
        body.materials = [face, face, rail, edge, edge]
        let bodyNode = SCNNode(geometry: body)
        phone.addChildNode(bodyNode)

        // Front glass: black, a hair inside the metal, with the same rounded corners; slightly
        // glossy so the environment leaves a faint sheen where it catches the light.
        let inset = depth * 0.30
        let glassPath = NSBezierPath(roundedRect: NSRect(x: -bodyWidth / 2 + inset, y: -bodyHeight / 2 + inset,
                                                         width: bodyWidth - 2 * inset, height: bodyHeight - 2 * inset),
                                     xRadius: corner - inset, yRadius: corner - inset)
        glassPath.flatness = 0.0005
        let glass = SCNShape(path: glassPath, extrusionDepth: 0.002)
        let glassMat = SCNMaterial()
        glassMat.lightingModel = .physicallyBased
        glassMat.diffuse.contents = NSColor(calibratedWhite: 0.02, alpha: 1)
        glassMat.metalness.contents = 0.0
        glassMat.roughness.contents = 0.15
        glass.materials = [glassMat]
        let glassNode = SCNNode(geometry: glass)
        glassNode.position = SCNVector3(0, 0, depth / 2 + 0.001)
        phone.addChildNode(glassNode)

        // The screen: an unlit plane (it is a light source) whose corners are masked round.
        let panel = SCNPlane(width: panelWidth, height: panelHeight)
        let screen = SCNMaterial()
        screen.lightingModel = .constant
        screen.diffuse.contents = NSColor.black
        screen.transparent.contents = roundedMask(size: CGSize(width: panelWidth, height: panelHeight),
                                                  radius: corner - bezel)
        screen.transparencyMode = .aOne
        screen.transparent.mipFilter = .none
        screen.transparent.magnificationFilter = .linear
        screen.isDoubleSided = false
        panel.materials = [screen]
        let panelNode = SCNNode(geometry: panel)
        panelNode.position = SCNVector3(0, 0, depth / 2 + 0.004)
        phone.addChildNode(panelNode)

        // Punch hole, centred under the top edge: a recessed black ring with a lens inside that
        // carries a deep indigo coating glint — optical depth instead of a flat dot.
        let holeRadius = bodyWidth * 0.016
        let holeY = panelHeight / 2 - panelWidth * 0.045
        let ring = SCNCylinder(radius: holeRadius, height: 0.003)
        ring.firstMaterial?.diffuse.contents = NSColor.black
        ring.firstMaterial?.lightingModel = .constant
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        ringNode.position = SCNVector3(0, holeY, depth / 2 + 0.005)
        phone.addChildNode(ringNode)
        let lens = SCNSphere(radius: holeRadius * 0.55)
        let lensMat = SCNMaterial()
        lensMat.lightingModel = .physicallyBased
        lensMat.diffuse.contents = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.22, alpha: 1)
        lensMat.metalness.contents = 0.3
        lensMat.roughness.contents = 0.12
        lens.materials = [lensMat]
        let lensNode = SCNNode(geometry: lens)
        lensNode.position = SCNVector3(0, holeY, depth / 2 + 0.004)
        phone.addChildNode(lensNode)

        // Matte polymer for the antenna breaks and the speaker slit.
        let matte = SCNMaterial()
        matte.lightingModel = .physicallyBased
        matte.diffuse.contents = finish.body.blended(withFraction: 0.35, of: .black) ?? finish.body
        matte.metalness.contents = 0.0
        matte.roughness.contents = 0.85

        // Hairline speaker slit in the top bezel, over the glass edge.
        let slit = SCNBox(width: bodyWidth * 0.14, height: bodyWidth * 0.005, length: 0.002, chamferRadius: 0.001)
        slit.materials = [matte]
        let slitNode = SCNNode(geometry: slit)
        slitNode.position = SCNVector3(0, bodyHeight / 2 - bezel * 0.55, depth / 2 + 0.0045)
        phone.addChildNode(slitNode)

        // Antenna breaks: thin polymer bands through the rail near the corners — two on the
        // near rail, two across the top — so the metal edge is not one unbroken line.
        let band = bodyWidth * 0.006
        for y in [bodyHeight * 0.40, -bodyHeight * 0.40] {
            let cut = SCNBox(width: depth * 0.35, height: band, length: depth * 0.96, chamferRadius: 0)
            cut.materials = [matte]
            let node = SCNNode(geometry: cut)
            node.position = SCNVector3(-bodyWidth / 2 + depth * 0.10, y, 0)
            phone.addChildNode(node)
        }
        for x in [-bodyWidth * 0.32, bodyWidth * 0.32] {
            let cut = SCNBox(width: band, height: depth * 0.35, length: depth * 0.96, chamferRadius: 0)
            cut.materials = [matte]
            let node = SCNNode(geometry: cut)
            node.position = SCNVector3(x, bodyHeight / 2 - depth * 0.10, 0)
            phone.addChildNode(node)
        }

        // Side buttons on the RIGHT rail, where a Pixel wears them: the power key above, the
        // volume rocker below it, both standing a hair proud of the rail.
        let buttonMetal = SCNMaterial()
        buttonMetal.lightingModel = .physicallyBased
        buttonMetal.diffuse.contents = finish.rail
        buttonMetal.metalness.contents = 0.96
        buttonMetal.roughness.contents = 0.12
        for (y, length) in [(bodyHeight * 0.26, bodyHeight * 0.06), (bodyHeight * 0.12, bodyHeight * 0.11)] {
            let button = SCNBox(width: depth * 0.22, height: length, length: depth * 0.55,
                                chamferRadius: depth * 0.08)
            button.materials = [buttonMetal]
            let node = SCNNode(geometry: button)
            node.position = SCNVector3(bodyWidth / 2 + depth * 0.06, y, 0)
            phone.addChildNode(node)
        }

        if cameraIsland {
            phone.addChildNode(makeCameraIsland(bodyWidth: bodyWidth, bodyHeight: bodyHeight,
                                                depth: depth, finish: finish))
        }
        return (phone, screen, bodyWidth, bodyHeight, depth)
    }

    /// The camera island on the back, as a current Pixel wears it: a raised pill inset from both
    /// rails, its own chamfer catching the same rim light as the body, a glossy black glass
    /// panel recessed into it, and three lens barrels standing proud with a metal ring, a deep
    /// glass dome and a coated highlight. The flash and the sensor sit at the far end.
    ///
    /// It is built here rather than in the twin so both views share it. A hero shot swinging
    /// past the back sees the same phone the twin does when you turn it over.
    private static func makeCameraIsland(bodyWidth: CGFloat, bodyHeight: CGFloat,
                                         depth: CGFloat, finish: HeroFinish) -> SCNNode {
        func pbr(_ color: NSColor, _ metalness: CGFloat, _ roughness: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = metalness
            m.roughness.contents = roughness
            return m
        }

        let island = SCNNode()
        // Proportions read off doc/pixel-backside.png and the three-view reference: the island
        // is clearly inset from BOTH rails, not full width, and sits high on the back.
        let islandW = bodyWidth * 0.74
        let islandH = bodyHeight * 0.145
        let islandD = depth * 0.34                 // how far it stands off the back
        let centreY = bodyHeight * 0.295
        let backZ = -depth / 2                     // the back face

        // The raised pill. Extruded from a rounded path so its rim is a curve, like the body's.
        let path = NSBezierPath(roundedRect: NSRect(x: -islandW / 2, y: -islandH / 2,
                                                    width: islandW, height: islandH),
                                xRadius: islandH / 2, yRadius: islandH / 2)
        path.flatness = 0.0005
        let pill = SCNShape(path: path, extrusionDepth: islandD)
        pill.chamferMode = .both
        pill.chamferRadius = islandD * 0.30
        // The island body is nearly black on a real Pixel; what you see of it is the bright
        // ring of its rim, not the face.
        let shell = pbr(NSColor(calibratedWhite: 0.045, alpha: 1), 0.65, 0.22)
        let rim = pbr(finish.chamfer, 1.0, 0.05)
        pill.materials = [shell, shell, shell, rim, rim]
        let pillNode = SCNNode(geometry: pill)
        pillNode.position = SCNVector3(0, centreY, backZ - islandD / 2)
        island.addChildNode(pillNode)

        // Black glass across the pill's face, a hair proud, so the lenses sit in glass and not
        // in metal. Glossy and nearly black: it is the darkest thing on the phone.
        let inset = islandH * 0.07
        let glassPath = NSBezierPath(roundedRect: NSRect(x: -islandW / 2 + inset, y: -islandH / 2 + inset,
                                                         width: islandW - inset * 2,
                                                         height: islandH - inset * 2),
                                     xRadius: (islandH - inset * 2) / 2,
                                     yRadius: (islandH - inset * 2) / 2)
        glassPath.flatness = 0.0005
        let glass = SCNShape(path: glassPath, extrusionDepth: 0.002)
        glass.materials = [pbr(NSColor(calibratedWhite: 0.015, alpha: 1), 0.0, 0.06)]
        let glassNode = SCNNode(geometry: glass)
        glassNode.position = SCNVector3(0, centreY, backZ - islandD - 0.001)
        island.addChildNode(glassNode)

        // Three lenses in a row. Each is a ring, a dome of dark glass, and a small bright dot
        // for the coating — that dot is what stops a lens reading as a flat black circle.
        let ringMetal = pbr(NSColor(calibratedWhite: 0.22, alpha: 1), 0.9, 0.16)
        let lensGlass = pbr(NSColor(srgbRed: 0.02, green: 0.03, blue: 0.06, alpha: 1), 0.35, 0.03)
        let coating = pbr(NSColor(srgbRed: 0.30, green: 0.45, blue: 0.85, alpha: 1), 0.2, 0.02)
        // Lenses fill one end of the island with clear gaps between them, and the flash sits
        // alone at the other. On the phone's LEFT side, which is what a back view shows on the
        // right — the same side the reference photo puts it.
        let lensR = islandH * 0.24
        for x in [islandW * 0.32, islandW * 0.10, -islandW * 0.12] {
            let ring = SCNTube(innerRadius: lensR * 0.88, outerRadius: lensR, height: islandD * 0.42)
            ring.materials = [ringMetal]
            let ringNode = SCNNode(geometry: ring)
            ringNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
            ringNode.position = SCNVector3(x, centreY, backZ - islandD - islandD * 0.20)
            island.addChildNode(ringNode)

            let dome = SCNSphere(radius: lensR * 0.88)
            dome.materials = [lensGlass]
            let domeNode = SCNNode(geometry: dome)
            domeNode.scale = SCNVector3(1, 1, 0.26)          // a shallow dome, not a ball
            domeNode.position = SCNVector3(x, centreY, backZ - islandD - islandD * 0.12)
            island.addChildNode(domeNode)

            let glint = SCNSphere(radius: lensR * 0.20)
            glint.materials = [coating]
            let glintNode = SCNNode(geometry: glint)
            glintNode.scale = SCNVector3(1, 1, 0.30)
            glintNode.position = SCNVector3(x - lensR * 0.28, centreY + lensR * 0.28,
                                            backZ - islandD - islandD * 0.26)
            island.addChildNode(glintNode)
        }

        // Flash and the sensor window at the far end of the island.
        let flash = SCNSphere(radius: lensR * 0.46)
        flash.materials = [pbr(NSColor(srgbRed: 0.99, green: 0.98, blue: 0.94, alpha: 1), 0.0, 0.22)]
        let flashNode = SCNNode(geometry: flash)
        flashNode.scale = SCNVector3(1, 1, 0.16)
        flashNode.position = SCNVector3(-islandW * 0.34, centreY, backZ - islandD - 0.002)
        island.addChildNode(flashNode)

        let sensor = SCNSphere(radius: lensR * 0.12)
        sensor.materials = [pbr(NSColor(calibratedWhite: 0.06, alpha: 1), 0.0, 0.30)]
        let sensorNode = SCNNode(geometry: sensor)
        sensorNode.scale = SCNVector3(1, 1, 0.30)
        sensorNode.position = SCNVector3(-islandW * 0.23, centreY, backZ - islandD - 0.002)
        island.addChildNode(sensorNode)

        // The G low on the back, the way a real Pixel wears it: not the colour logo but a
        // monochrome mark a shade darker than the panel, catching the light as the phone turns.
        let gSize = bodyWidth * 0.24
        let gPlane = SCNPlane(width: gSize, height: gSize)
        let gMaterial = SCNMaterial()
        gMaterial.lightingModel = .constant
        gMaterial.diffuse.contents = TwinView.googleGImage(side: 512)
        gMaterial.isDoubleSided = false
        gPlane.materials = [gMaterial]
        let gNode = SCNNode(geometry: gPlane)
        gNode.position = SCNVector3(0, -bodyHeight * 0.05, backZ - 0.001)
        gNode.eulerAngles = SCNVector3(0, CGFloat.pi, 0)      // turn to face out the back
        island.addChildNode(gNode)

        return island
    }

    /// A white rounded rectangle on clear, for masking the screen's corners.
    private static func roundedMask(size: CGSize, radius: CGFloat) -> NSImage {
        let px = CGSize(width: 2048, height: (2048 * size.height / size.width).rounded())
        let r = radius / size.width * px.width
        let image = NSImage(size: px)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: px).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: px), xRadius: r, yRadius: r).fill()
        image.unlockFocus()
        return image
    }

    /// An equirectangular studio: a bright sky, a dark floor, and a hot horizontal softbox
    /// above the horizon — the reflection that reads as "polished metal" on a rounded rail.
    private static func studioEnvironment() -> NSImage {
        // What a rounded metal rail shows you is a picture of the room, squeezed. So the room is
        // built to be squeezed: a nearly black field with a few small, HARD-edged bright strips.
        // A wide soft glow smears into the broad gradient we had before; a narrow hard strip
        // reflects as the razor-thin line a real chamfer catches, and it brightens through the
        // corners on its own as the surface turns.
        let size = NSSize(width: 1024, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        let sky = NSGradient(colorsAndLocations:
            (NSColor(calibratedWhite: 0.30, alpha: 1), 0.0),
            (NSColor(calibratedWhite: 0.10, alpha: 1), 0.42),
            (NSColor(calibratedWhite: 0.03, alpha: 1), 0.52),
            (NSColor(calibratedWhite: 0.01, alpha: 1), 1.0))
        sky?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        // Key strip, above the horizon and slightly left of centre: the main rim line.
        NSColor(calibratedWhite: 1.0, alpha: 1).setFill()
        NSRect(x: 150, y: 322, width: 470, height: 13).fill()
        // A dimmer, shorter strip opposite, so the far rail is separated from the background
        // instead of vanishing, and a small hot square for a glint on the corners.
        NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
        NSRect(x: 700, y: 300, width: 250, height: 8).fill()
        NSColor(calibratedWhite: 1.0, alpha: 1).setFill()
        NSRect(x: 60, y: 360, width: 46, height: 46).fill()
        image.unlockFocus()
        return image
    }

    // MARK: - shadow

    /// The phone's silhouette as a soft black shadow: alpha kept, colour dropped, blurred wide.
    private func shadowImage(of phone: CGImage, scale: CGFloat) -> CGImage? {
        let source = CIImage(cgImage: phone)
        guard let tint = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: source,
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.65),
        ])?.outputImage,
              let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: tint, kCIInputRadiusKey: 40 * scale])?.outputImage else { return nil }
        return ciContext.createCGImage(blurred, from: source.extent)
    }

    // MARK: - accent from the screen

    /// A pastel of the screen's dominant vivid hue — the headline's accent matched to the app,
    /// as Studio's lavender matches Studio. Nil when the screen has no colour worth taking.
    func sampleAccent() -> NSColor? {
        guard let image = lastImage else { return nil }
        let n = 24
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var sx = 0.0, sy = 0.0, weight = 0.0
        for i in 0..<(n * n) {
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255,
                            blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            let sat = c.saturationComponent, bri = c.brightnessComponent
            guard sat > 0.35, bri > 0.35 else { continue }        // greys and blacks carry no hue
            let w = Double(sat * bri)
            let a = Double(c.hueComponent) * 2 * .pi
            sx += cos(a) * w; sy += sin(a) * w; weight += w
        }
        guard weight > 0.5 else { return nil }
        var hue = atan2(sy, sx) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return NSColor(hue: CGFloat(hue), saturation: 0.42, brightness: 0.95, alpha: 1)
    }

    // MARK: - output helpers

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "HeroComposer", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.lastPathComponent)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "HeroComposer", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.lastPathComponent)"])
        }
    }

    /// A BGRA pixel buffer holding `image`, for the recorder.
    static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}
