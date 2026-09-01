//
//  MirrorView.swift
//  The View Screen: shows the device, turns clicks and drags into touches.
//
//  The coded video is not the display. ComputeVideoSize in the agent rounds the encode width up
//  to a multiple of 8 (for ffmpeg's benefit) and the height up to a multiple of 2, then the
//  picture is letterboxed inside that — CENTRED vertically, which is the one place this differs
//  from ~/rplay-hub. displayservice anchors its padding top-left; MediaCodec's lands as equal
//  black strips top and bottom, so cropping to the top-left corner here would show one strip and
//  shift every touch by half the other.
//
//  Studio computes the same crop in VideoDecoder.kt:
//      imageHeight = frameWidth * rotatedDisplayHeight / rotatedDisplayWidth, capped at frameHeight
//      startY      = (frameHeight - imageHeight) / 2
//
//  Layer arrangement, since videoGravity alone cannot express that crop:
//      backing layer (clips)
//        └─ clipLayer     == exactly the on-screen rectangle of the device display
//             └─ displayLayer == the whole coded frame, scaled and offset so its live band fills
//
//  Geometry comes from the packet header, on every frame, so rotation and resize need no side
//  channel — the picture simply starts arriving with a different header.
//

import AppKit
import AVFoundation

final class MirrorView: NSView, NSMenuItemValidation {
    /// Coded frame size, from the parameter sets. Includes the alignment padding.
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { needsLayout = true } } }

    /// The display in its canonical orientation, from the packet header.
    var displaySize: CGSize = .zero { didSet { if displaySize != oldValue { needsLayout = true } } }

    /// Quadrants the display is currently rotated by.
    var displayOrientation = 0 { didSet { if displayOrientation != oldValue { needsLayout = true } } }

    /// Quadrants the agent already rotated the picture by, so we do not rotate twice.
    var orientationCorrection = 0 {
        didSet { if orientationCorrection != oldValue { needsLayout = true } }
    }

    /// Watches. The agent flags them and the display is genuinely circular.
    var isRoundDisplay = false { didSet { if isRoundDisplay != oldValue { needsLayout = true } } }

    /// The physical screen outline, asked of the device. Nil until known, and nil forever on a
    /// device that reports no cutout or rounding.
    var displayShape: DisplayShape? {
        didSet { if displayShape != oldValue { needsLayout = true } }
    }

    /// Where control messages go. Nil until the session is up, which is also what gates input.
    var control: ControlSender?

    /// Which device display the picture (and with it every touch) belongs to. 0 is built-in.
    var displayId: Int32 = 0

    /// The View Screen button was pressed, or the idle mockup was clicked.
    var onViewScreen: (() -> Void)?

    /// Files dropped on the mirror — APKs install, everything else lands in the device's
    /// Download folder, the way scrcpy's window does it. Only fires with a live session.
    var onFilesDropped: (([URL]) -> Void)?

    /// A right-click menu item was chosen.
    var onCommand: ((Command) -> Void)?

    /// What the right-click menu offers. Device Hub puts these on the screen itself rather than
    /// in a side pane, because they act on the picture.
    enum Command: String {
        case screenshot, record, home, back, recents, rotate
        case pin, openWindow, openTab
        case wake, power
        case stop, reconnect
        case twin
    }

    /// Shown under the mockup while idle, the way Device Hub labels its pre-connect device.
    var deviceName: String? {
        didSet { nameLabel.stringValue = deviceName ?? "No device selected"; needsLayout = true }
    }
    var deviceSubtitle: String? {
        didSet { osLabel.stringValue = deviceSubtitle ?? ""; needsLayout = true }
    }

    let displayLayer = VideoLayer()
    private let clipLayer = CALayer()
    private let cutoutLayer = CAShapeLayer()

    /// The black surround drawn around a live picture, in points.
    private static let bezelWidth: CGFloat = 14
    private let placeholderLayer = CAGradientLayer()
    private let nameLabel = NSTextField(labelWithString: "No device selected")
    private let osLabel = NSTextField(labelWithString: "")
    private let viewScreenButton = HoverButton()
    private var viewScreenStack: NSStackView!

    /// True before the first frame — draws the mockup instead of a black rectangle.
    private var isGated = true { didSet { if isGated != oldValue { needsLayout = true } } }
    /// When false, an arriving video header does NOT auto-reveal the picture — the session runs
    /// prepared behind the View Screen gate until the user asks. Set true to show it instantly.
    var autoReveal = true

    /// Fusion windows want the raw picture: no bezel ring, no rounded corners — the video runs
    /// to the window's edge. The main stage keeps its device bezel.
    var borderless = false { didSet { if borderless != oldValue { needsLayout = true } } }

    /// Naked windows paint the surround black (seamless with the phone's bezel) instead of the
    /// Device-Hub white, so no white shows around the phone in a raw window.
    var nakedBackground = false {
        didSet {
            guard nakedBackground != oldValue else { return }
            layer?.backgroundColor = (nakedBackground ? NSColor.black : NSColor.white).cgColor
        }
    }

    /// The view is deliberately flipped. AppKit flips the backing layer's geometry for a
    /// non-flipped view, which flips manually added sublayers' content too and renders the video
    /// upside down; flipping the view fixes that and gives a top-left origin matching the
    /// device's, so no y inversion is needed anywhere below.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpLayers()
    }

    /// A click should reach the device even when the window was not already focused — otherwise
    /// the first click of every visit is swallowed activating the app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildContextMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ command: Command, _ symbol: String? = nil) {
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            }
            menu.addItem(item)
        }
        add("Take Screenshot", .screenshot, "camera")
        add("Record Screen", .record, "record.circle")
        recordItem = menu.items.last
        menu.addItem(.separator())
        add("Back", .back, "chevron.backward")
        add("Home", .home, "circle")
        add("Recents", .recents, "square")
        add("Rotate", .rotate, "rotate.right")
        menu.addItem(.separator())
        add("Wake", .wake, "sun.max")
        add("Power Button", .power, "power")
        menu.addItem(.separator())
        add("View in 3D", .twin, "cube.transparent")
        twinItem = menu.items.last
        menu.addItem(.separator())
        twinSeparator = menu.items.last
        twinItem?.isHidden = !AppBuild.twinEnabled
        twinSeparator?.isHidden = !AppBuild.twinEnabled
        add("Open in New Window", .openWindow, "macwindow")
        add("Open in New Tab", .openTab, "square.on.square")
        pinItem = menu.items.last
        add("Pin Window on Top", .pin, "pin")
        pinItem = menu.items.last
        menu.addItem(.separator())
        add("Reconnect", .reconnect, "arrow.clockwise")
        add("Stop Mirroring", .stop, "stop.circle")
        // Deliberately NOT `self.menu`. These commands act on the device, so they belong on the
        // device's row in the sidebar; the app moves them there. The items still target this
        // view, so `contextAction` and `validateMenuItem` keep working unchanged.
        commandMenu = menu
    }

    /// The device commands, built but unattached. AppDelegate hangs them off the sidebar row.
    private(set) var commandMenu: NSMenu?

    private var pinItem: NSMenuItem?
    private var recordItem: NSMenuItem?
    private var twinItem: NSMenuItem?
    private var twinSeparator: NSMenuItem?

    /// The twin gate flipped; show or hide its menu entry to match.
    func setTwinVisible(_ visible: Bool) {
        twinItem?.isHidden = !visible
        twinSeparator?.isHidden = !visible
    }

    /// The 3D mode toggled; make the item say what it will do next.
    func setTwinActive(_ active: Bool) {
        twinItem?.title = active ? "Exit 3D View" : "View in 3D"
        twinItem?.image = NSImage(systemSymbolName: active ? "cube.fill" : "cube.transparent",
                                  accessibilityDescription: "3D")
    }

    /// Keep the menu item in step with the strip button, so both say what they will do next.
    func setRecording(_ recording: Bool) {
        recordItem?.title = recording ? "Stop Recording" : "Record Screen"
        recordItem?.image = NSImage(
            systemSymbolName: recording ? "stop.circle.fill" : "record.circle",
            accessibilityDescription: "Record")
    }

    /// Reflect the pinned state back into the menu, so the item says what it will do next.
    func setPinned(_ pinned: Bool) {
        pinItem?.title = pinned ? "Unpin Window" : "Pin Window on Top"
        pinItem?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                 accessibilityDescription: "Pin")
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = Command(rawValue: raw) else { return }
        onCommand?(command)
    }

    /// Grey out what cannot work without a live session, rather than letting it fail silently.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String,
              let command = Command(rawValue: raw) else { return true }
        switch command {
        case .pin, .openWindow, .openTab, .reconnect: return true
        default:                                      return control != nil
        }
    }

    // MARK: - drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard control != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        else { return [] }
        setDropHighlight(true)   // show the picture is a drop target
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        guard control != nil,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: nil) as? [URL],
              !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    /// A glowing accent ring around the picture while a file hovers, so the drop target reads. The
    /// bezel's own border is restored by the next layout(); a manual layout() call repaints it.
    private func setDropHighlight(_ on: Bool) {
        clipLayer.borderColor = on ? NSColor.controlAccentColor.cgColor : NSColor.black.cgColor
        clipLayer.borderWidth = on ? max(3, Self.bezelWidth) : (borderless ? 0 : Self.bezelWidth)
        if !on { needsLayout = true }
    }

    private func setUpLayers() {
        buildContextMenu()
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.masksToBounds = true
        // Matches ~/rplay-hub: the mirror pane is white, the two side panes 0xFAFAFA.
        layer?.backgroundColor = NSColor.white.cgColor

        placeholderLayer.colors = [
            NSColor(srgbRed: 0.31, green: 0.33, blue: 0.42, alpha: 1).cgColor,
            NSColor(srgbRed: 0.16, green: 0.18, blue: 0.25, alpha: 1).cgColor,
        ]
        placeholderLayer.startPoint = CGPoint(x: 0, y: 0)
        placeholderLayer.endPoint = CGPoint(x: 1, y: 1)

        clipLayer.masksToBounds = true
        clipLayer.borderColor = NSColor.black.cgColor
        clipLayer.addSublayer(placeholderLayer)

        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = NSColor.black.cgColor
        clipLayer.addSublayer(displayLayer)

        // Over the picture: the camera hole, which is real screen area the panel cannot light.
        cutoutLayer.fillColor = NSColor.black.cgColor
        cutoutLayer.isHidden = true
        clipLayer.addSublayer(cutoutLayer)

        layer?.addSublayer(clipLayer)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.alignment = .center
        osLabel.font = .systemFont(ofSize: 11)
        osLabel.textColor = .secondaryLabelColor
        osLabel.alignment = .center

        viewScreenStack = NSStackView(views: [nameLabel, osLabel])
        viewScreenStack.orientation = .vertical
        viewScreenStack.alignment = .centerX
        viewScreenStack.spacing = 2
        addSubview(viewScreenStack)

        // Device Hub's own icon: the stock screen-sharing symbol.
        viewScreenButton.image = NSImage(systemSymbolName: "rectangle.inset.filled.and.person.filled",
                                         accessibilityDescription: "View Screen")
        viewScreenButton.imagePosition = .imageLeading
        // The button is 127pt, wider than its content, so image and title have to travel
        // together or the cell pins the image to the leading edge and centres only the text —
        // which is what left the icon sitting in the capsule's rounded end with a gulf after it.
        // imageHugsTitle is the switch that makes the image ride next to the title instead of
        // against the edge; `alignment` then centres the pair as one group.
        viewScreenButton.imageHugsTitle = true
        viewScreenButton.alignment = .center
        viewScreenButton.title = " View Screen"
        viewScreenButton.target = self
        viewScreenButton.action = #selector(viewScreenPressed)
        addSubview(viewScreenButton)
    }

    @objc private func viewScreenPressed() { onViewScreen?() }

    /// The button lights when this panel is the focused one and its window is key — the same
    /// rule the iOS app's does, and nothing to do with the pointer.
    override func becomeFirstResponder() -> Bool {
        viewScreenButton.isFocusedPanel = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        viewScreenButton.isFocusedPanel = false
        return super.resignFirstResponder()
    }

    /// Called on the main queue as each packet header changes.
    func apply(header: VideoPacketHeader) {
        if Int(header.displayOrientation) != displayOrientation
            || Int(header.displayOrientationCorrection) != orientationCorrection {
            AppBuild.log("orientation=\(header.displayOrientation) "
                         + "correction=\(header.displayOrientationCorrection) "
                         + "display=\(header.displaySize)")
        }
        displaySize = header.displaySize
        displayOrientation = Int(header.displayOrientation)
        orientationCorrection = Int(header.displayOrientationCorrection)
        isRoundDisplay = header.isDisplayRound && header.displayWidth == header.displayHeight
        if isGated, autoReveal { isGated = false }
    }

    /// Show a prepared session's picture now — the user pressed View Screen / Start Mirroring.
    func reveal() {
        autoReveal = true
        if isGated { isGated = false }
    }

    func reset() {
        isGated = true
        autoReveal = true
        videoSize = .zero
        displaySize = .zero
        displayOrientation = 0
        orientationCorrection = 0
        control = nil
        displayShape = nil
        displayLayer.flushAndRemoveImage()
        needsLayout = true
    }

    // MARK: - geometry

    /// The display as the picture presents it.
    /// Quadrants the picture is presented at, as one definition rather than three.
    ///
    /// The agent pre-rotates by `orientationCorrection` and reports both numbers. When the
    /// correction is odd it has already absorbed the whole rotation, so the presented angle is
    /// `displayOrientation` alone; when it is even the two add. `devicePoint` has always used
    /// this rule for clicks, but `rotatedDisplaySize` used `displayOrientation - correction`,
    /// and the two disagree by 90 degrees exactly when the correction is odd.
    ///
    /// A Pixel 9a in landscape reports orientation=1 correction=1: the old expression gave 0,
    /// so the frame stayed portrait while the picture inside it was landscape, letterboxed.
    private var presentedQuadrants: Int {
        let raw = orientationCorrection % 2 == 0
            ? displayOrientation + orientationCorrection
            : displayOrientation
        return ((raw % 4) + 4) % 4
    }

    private var rotatedDisplaySize: CGSize {
        guard displaySize.width > 0 else { return CGSize(width: 9, height: 19.5) }
        // The bezel must match what is actually DRAWN, and the drawn aspect is the coded frame's,
        // turned by the correction the sublayerTransform applies. Keying this off the header's
        // orientation raced the decoder — the header and the frame arrive through different
        // paths, and after a few quick rotations the mirror could stick with a portrait bezel
        // around landscape content. The frame cannot disagree with itself, so prefer it.
        if videoSize.width > 0, videoSize.height > 0 {
            let landscape = orientationCorrection % 2 == 1
                ? videoSize.height > videoSize.width
                : videoSize.width > videoSize.height
            // Orient displaySize to MATCH the frame — never blind-swap: a phone's canonical size
            // is portrait, but a virtual display's is landscape-native, and swapping that drew a
            // portrait bezel around a 1920x1080 stream.
            let displayLandscape = displaySize.width > displaySize.height
            return landscape == displayLandscape
                ? displaySize
                : CGSize(width: displaySize.height, height: displaySize.width)
        }
        return presentedQuadrants % 2 == 1
            ? CGSize(width: displaySize.height, height: displaySize.width)
            : displaySize
    }

    /// The display as the CODED PICTURE sees it — before `sublayerTransform` undoes the agent's
    /// pre-rotation. Distinct from `rotatedDisplaySize`, which is what the viewer ends up seeing.
    ///
    /// The crop maths needs this one: the band it is measuring lives in the encoder's frame, not
    /// on screen. Sharing a single "rotated size" between the two is what made the picture show
    /// one magnified corner after the frame started rotating correctly.
    private var codedDisplaySize: CGSize {
        guard displaySize.width > 0 else { return CGSize(width: 9, height: 19.5) }
        let quadrants = ((displayOrientation - orientationCorrection) % 4 + 4) % 4
        return quadrants % 2 == 1
            ? CGSize(width: displaySize.height, height: displaySize.width)
            : displaySize
    }

    /// Where the display sits inside the view, aspect-fit. Clicks map against THIS, never against
    /// `bounds` — that is the classic off-by-a-letterbox bug.
    private func displayRect() -> CGRect {
        let content = rotatedDisplaySize
        guard content.width > 0, content.height > 0 else { return bounds }
        if isGated {
            // A small mockup rather than the picture scaled to fill, matching the shape the
            // Device Hub clone uses before a stream exists.
            let targetWidth = min(bounds.width * 0.6, 120)
            let scale = targetWidth / content.width
            let w = content.width * scale
            let h = content.height * scale
            // The block is phone + gap + labels + gap + button, centred as a whole.
            let stackHeight = viewScreenStack?.fittingSize.height ?? 0
            let blockHeight = h + 16 + stackHeight + 10 + 29
            return CGRect(x: (bounds.width - w) / 2,
                          y: max(20, (bounds.height - blockHeight) / 2),
                          width: w, height: h)
        }
        let inset: CGFloat = borderless ? 0 : 12   // fusion windows want the picture flush
        let available = bounds.insetBy(dx: inset, dy: inset)
        let scale = min(available.width / content.width, available.height / content.height)
        let w = content.width * scale
        let h = content.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// The live band inside the coded frame: its height, and where it starts.
    ///
    /// Straight from the agent's alignment rule — the frame's WIDTH is always the real thing and
    /// only the height is padded, because ComputeVideoSize derives the height from the width.
    private var liveBand: (height: CGFloat, startY: CGFloat) {
        let frameW = videoSize.width, frameH = videoSize.height
        let display = codedDisplaySize
        guard frameW > 0, frameH > 0, display.width > 0 else { return (frameH, 0) }
        let imageHeight = min((frameW * display.height / display.width).rounded(), frameH)
        return (imageHeight, ((frameH - imageHeight) / 2).rounded(.down))
    }

    override func layout() {
        super.layout()
        let rect = displayRect()

        CATransaction.begin()
        CATransaction.setDisableActions(true)     // no interpolation: this resizes with the pane

        clipLayer.frame = rect
        clipLayer.cornerRadius = borderless ? 0 : cornerRadius(for: rect)
        // Device Hub keeps a black bezel around the live screen, not a hairline — it is what
        // makes the picture read as a phone rather than as a rectangle of video. The idle
        // mockup's bezel stays proportional to its own small size.
        clipLayer.borderWidth = borderless ? 0 : (isGated ? max(1, rect.width * 0.05) : Self.bezelWidth)
        placeholderLayer.frame = clipLayer.bounds
        placeholderLayer.isHidden = !isGated
        placeholderLayer.cornerRadius = clipLayer.cornerRadius
        displayLayer.isHidden = isGated

        viewScreenStack.isHidden = !isGated
        viewScreenButton.isHidden = !isGated
        if isGated {
            let fit = viewScreenStack.fittingSize
            viewScreenStack.frame = CGRect(x: (bounds.width - fit.width) / 2, y: rect.maxY + 16,
                                           width: fit.width, height: fit.height)
            let size = viewScreenButton.intrinsicContentSize
            viewScreenButton.frame = CGRect(x: (bounds.width - size.width) / 2,
                                            y: viewScreenStack.frame.maxY + 10,
                                            width: size.width, height: size.height)
        }

        // The agent pre-rotated the picture by `orientationCorrection`; undo that here rather
        // than in the crop maths, which is expressed in the picture's own frame.
        clipLayer.sublayerTransform = orientationCorrection == 0
            ? CATransform3DIdentity
            : CATransform3DMakeRotation(-CGFloat(orientationCorrection) * .pi / 2, 0, 0, 1)

        layOutCutout(in: rect)

        guard !isGated, videoSize.width > 0, videoSize.height > 0 else {
            displayLayer.frame = clipLayer.bounds
            CATransaction.commit()
            return
        }

        // Scale the coded frame so its live band exactly fills clipLayer, and push the top black
        // strip up out of the clip.
        let band = liveBand
        if orientationCorrection % 2 == 1 {
            // The sublayerTransform above turns the coded frame 90°/270° about clipLayer's centre,
            // so size the layer in the CODED frame's own axes — its height becomes the presented
            // width — and centre it; a centred rect rotates onto the clip exactly. Sizing this in
            // presented axes (the even-case formula) is what showed one magnified corner plus a
            // white strip whenever the device turned 90°.
            let scale = rect.width / videoSize.height
            let w = videoSize.width * scale
            let h = videoSize.height * scale
            displayLayer.frame = CGRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2,
                                        width: w, height: h)
        } else {
            let scale = rect.width / videoSize.width
            displayLayer.frame = CGRect(x: 0, y: -band.startY * scale,
                                        width: videoSize.width * scale,
                                        height: videoSize.height * scale)
        }
        CATransaction.commit()
    }

    // MARK: - device silhouette

    private func cornerRadius(for rect: CGRect) -> CGFloat {
        if isRoundDisplay { return rect.width / 2 }
        // The device's own radius, in its pixels, scaled to however big we are drawing it.
        if let shape = displayShape, shape.cornerRadius > 0, shape.displaySize.width > 0 {
            let presented = rotatedDisplaySize
            let scale = rect.width / max(presented.width, 1)
            return shape.cornerRadius * scale
        }
        return min(12, rect.width * 0.04)
    }

    /// Place the camera hole. Its coordinates are in the display's canonical orientation, and we
    /// are drawing the display as currently rotated, so they have to be turned to match — the
    /// inverse of the mapping `devicePoint` applies to clicks.
    private func layOutCutout(in rect: CGRect) {
        if isGated {
            // The idle mockup stands in for a phone we have not queried yet, so give it the
            // punch-hole a Pixel has — centred on the top edge — rather than leaving a blank
            // slab. A real device replaces this with its own reported cutout below.
            cutoutLayer.frame = clipLayer.bounds
            let r = max(1.5, rect.width * 0.035)
            let cy = r + rect.width * 0.05
            let box = CGRect(x: rect.width / 2 - r, y: cy - r, width: r * 2, height: r * 2)
            cutoutLayer.path = CGPath(ellipseIn: box, transform: nil)
            cutoutLayer.isHidden = false
            return
        }
        guard let shape = displayShape, let cutout = shape.cutout,
              shape.displaySize.width > 0, shape.displaySize.height > 0 else {
            cutoutLayer.isHidden = true
            return
        }
        let natural = shape.displaySize
        let quadrants = ((displayOrientation + orientationCorrection) % 4 + 4) % 4

        /// Natural pixels → a fraction of the picture as presented.
        func present(_ p: CGPoint) -> CGPoint {
            let nx = p.x / natural.width
            let ny = p.y / natural.height
            switch quadrants {
            case 1:  return CGPoint(x: ny, y: 1 - nx)
            case 2:  return CGPoint(x: 1 - nx, y: 1 - ny)
            case 3:  return CGPoint(x: 1 - ny, y: nx)
            default: return CGPoint(x: nx, y: ny)
            }
        }

        cutoutLayer.frame = clipLayer.bounds
        let w = rect.width, h = rect.height
        switch cutout {
        case .circle(let center, let radius):
            let c = present(center)
            // A circle stays a circle under a quarter turn, and the radius is in the display's
            // shorter dimension either way, so one scale factor is right for both axes.
            let scale = w / max(rotatedDisplaySize.width, 1)
            let r = radius * scale
            let box = CGRect(x: c.x * w - r, y: c.y * h - r, width: r * 2, height: r * 2)
            cutoutLayer.path = CGPath(ellipseIn: box, transform: nil)
        case .capsule(let box):
            let a = present(CGPoint(x: box.minX, y: box.minY))
            let b = present(CGPoint(x: box.maxX, y: box.maxY))
            let r = CGRect(x: min(a.x, b.x) * w, y: min(a.y, b.y) * h,
                           width: abs(b.x - a.x) * w, height: abs(b.y - a.y) * h)
            let radius = min(r.width, r.height) / 2
            cutoutLayer.path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius,
                                      transform: nil)
        }
        cutoutLayer.isHidden = false
    }

    // MARK: - input

    /// View point → device pixels in the display's ORIGINAL orientation, which is what
    /// MotionEventMessage wants. Nil when the click landed outside the picture.
    ///
    /// The rotation cases are Studio's own (AbstractDisplayView.toDeviceDisplayCoordinates),
    /// reduced to fractions. Getting this wrong is the worst kind of broken: the tap still lands,
    /// just somewhere else.
    private func devicePoint(_ p: CGPoint) -> CGPoint? {
        let r = displayRect()
        guard r.width > 0, r.height > 0, r.contains(p),
              displaySize.width > 0, displaySize.height > 0 else { return nil }
        let fx = (p.x - r.minX) / r.width
        let fy = (p.y - r.minY) / r.height

        let n: CGPoint
        switch presentedQuadrants {
        case 1:  n = CGPoint(x: 1 - fy, y: fx)
        case 2:  n = CGPoint(x: 1 - fx, y: 1 - fy)
        case 3:  n = CGPoint(x: fy, y: 1 - fx)
        default: n = CGPoint(x: fx, y: fy)
        }
        return CGPoint(x: (n.x * displaySize.width).rounded(),
                       y: (n.y * displaySize.height).rounded())
    }

    /// Every motion event carries its pointer, ACTION_UP included.
    ///
    /// The agent builds the MotionEvent entirely out of `message.pointers()` — it counts them,
    /// fills the coordinate array from them, and injects whatever that produces. Sending an empty
    /// array on UP yields a MotionEvent with pointer_count 0, which is malformed, so the gesture
    /// never completes and every tap is a DOWN that is never released.
    private func sendMotion(_ point: CGPoint, action: Int32) {
        guard let control else { return }
        let x = Int32(max(0, min(displaySize.width - 1, point.x)))
        let y = Int32(max(0, min(displaySize.height - 1, point.y)))
        control.send(ControlMessage.motionEvent(pointers: [.init(x: x, y: y)], action: action,
                                                displayId: displayId))
    }

    /// Inject a motion event from an already-mapped device point — used by the 3D twin, which does
    /// its own hit-test-to-device mapping but sends through this same path (control, clamp, id).
    func injectMotion(_ point: CGPoint, action: Int32) {
        sendMotion(point, action: action)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Only the View Screen button starts a session. Treating a click anywhere in the panel
        // as "start mirroring" meant merely focusing the window, or clicking past the mockup to
        // reach the pane, kicked off an agent deploy nobody asked for.
        guard control != nil else { return }
        guard let p = devicePoint(convert(event.locationInWindow, from: nil)) else { return }
        lastDevicePoint = p
        sendMotion(p, action: MotionAction.down)
    }

    override func mouseDragged(with event: NSEvent) {
        // Every intermediate position is sent. A tap and a swipe are not distinguished here the
        // way they are on the iOS path: that engine takes a gesture, this one takes raw motion
        // events, so the device's own gesture detector decides — which is what makes flings and
        // long-presses work without any of it being modelled here.
        guard let p = devicePoint(convert(event.locationInWindow, from: nil)) else { return }
        lastDevicePoint = p
        sendMotion(p, action: MotionAction.move)
    }

    override func mouseUp(with event: NSEvent) {
        // A drag that leaves the picture still has to be released, or the agent is left with an
        // unfinished gesture and its motion_event_start_time_ never resets. Clamp instead of
        // bailing out.
        let p = devicePoint(convert(event.locationInWindow, from: nil)) ?? lastDevicePoint
        guard let p else { return }
        sendMotion(p, action: MotionAction.up)
    }

    /// Where the pointer last was inside the picture, so a release outside it still lands.
    private var lastDevicePoint: CGPoint?

    override func scrollWheel(with event: NSEvent) {
        guard let control,
              let p = devicePoint(convert(event.locationInWindow, from: nil)) else { return }
        let x = Int32(max(0, min(displaySize.width - 1, p.x)))
        let y = Int32(max(0, min(displaySize.height - 1, p.y)))
        // Android counts scroll in notches, positive up; AppKit gives pixels, positive up too.
        let notches = Float(event.scrollingDeltaY / 40)
        guard notches != 0 else { return }
        control.send(ControlMessage.motionEvent(
            pointers: [.init(x: x, y: y, axisValues: [MotionAxis.vscroll: notches])],
            action: MotionAction.scroll,
            isMouse: true))
    }

    override func keyDown(with event: NSEvent) {
        guard let control else { super.keyDown(with: event); return }
        if let key = AndroidKeyMap.keycode(for: event) {
            control.send(ControlMessage.keyEvent(action: KeyAction.downAndUp, keycode: key))
            return
        }
        // Anything that produces text goes as text, so the device's own IME and layout apply
        // rather than us guessing a keycode per character.
        if let text = event.characters, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            control.send(ControlMessage.textInput(text))
            return
        }
        super.keyDown(with: event)
    }
}

/// The keys worth translating to Android keycodes. Everything else becomes text.
enum AndroidKeyMap {
    static func keycode(for event: NSEvent) -> Int32? {
        switch event.keyCode {
        case 51:  return AndroidKey.del            // delete
        case 117: return AndroidKey.forwardDel
        case 36, 76: return AndroidKey.enter
        case 53:  return AndroidKey.back           // escape reads as Back, as Studio does
        case 48:  return AndroidKey.tab
        case 123: return AndroidKey.dpadLeft
        case 124: return AndroidKey.dpadRight
        case 125: return AndroidKey.dpadDown
        case 126: return AndroidKey.dpadUp
        case 115: return AndroidKey.moveHome
        case 119: return AndroidKey.moveEnd
        default:  return nil
        }
    }
}


/// Device Hub's View Screen button: a grey capsule that turns solid indigo with white text when
/// the middle panel is focused and its window is key.
///
/// Drawn rather than bezelled. `bezelColor` does not take on a `.rounded` button — it keeps
/// rendering AppKit's default face whatever it is set to — so a borderless button with its own
/// layer background is the only way to get both the colour and the capsule shape. Carried over
/// from ~/rplay-hub, where the behaviour was worked out against the real Device Hub.
final class HoverButton: NSButton {
    var isFocusedPanel = false { didSet { if isFocusedPanel != oldValue { apply() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { apply() } } }
    private var observers: [NSObjectProtocol] = []

    static let resting = NSColor(srgbRed: 0xDC / 255, green: 0xDC / 255, blue: 0xDC / 255, alpha: 1)
    static let active = NSColor(srgbRed: 97 / 255.0, green: 85 / 255.0, blue: 245 / 255.0, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isBordered = false
        wantsLayer = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 127, height: 29) }

    // Fire on the first click even when the window is not key, so "View Screen" starts on one
    // click from an unfocused window instead of the click being spent just activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main) { [weak self] _ in self?.apply() })
        }
        apply()
    }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    // Show the active colour the instant the button is pressed — immediate feedback while the
    // session deploys, before the mirror replaces this view. super.mouseDown runs the tracking
    // loop and returns once the click completes, so the pressed state brackets exactly the click.
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    private func apply() {
        let lit = isFocusedPanel && (window?.isKeyWindow ?? false)
        let active = lit || isPressed
        var bg = active ? Self.active : Self.resting
        if isPressed { bg = bg.blended(withFraction: 0.18, of: .black) ?? bg }   // a pressed dip
        layer?.backgroundColor = bg.cgColor
        let fg: NSColor = active ? .white : .labelColor
        contentTintColor = fg
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: fg,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }
}
