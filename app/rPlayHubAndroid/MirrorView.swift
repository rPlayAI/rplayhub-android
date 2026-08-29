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

final class MirrorView: NSView {
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

    /// Where control messages go. Nil until the session is up, which is also what gates input.
    var control: ControlSender?

    /// The View Screen button was pressed, or the idle mockup was clicked.
    var onViewScreen: (() -> Void)?

    /// Shown under the mockup while idle, the way Device Hub labels its pre-connect device.
    var deviceName: String? {
        didSet { nameLabel.stringValue = deviceName ?? "No device selected"; needsLayout = true }
    }
    var deviceSubtitle: String? {
        didSet { osLabel.stringValue = deviceSubtitle ?? ""; needsLayout = true }
    }

    let displayLayer = VideoLayer()
    private let clipLayer = CALayer()
    private let placeholderLayer = CAGradientLayer()
    private let nameLabel = NSTextField(labelWithString: "No device selected")
    private let osLabel = NSTextField(labelWithString: "")
    private let viewScreenButton = HoverButton()
    private var viewScreenStack: NSStackView!

    /// True before the first frame — draws the mockup instead of a black rectangle.
    private var isGated = true { didSet { if isGated != oldValue { needsLayout = true } } }

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

    private func setUpLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

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

        viewScreenButton.title = "View Screen"
        viewScreenButton.image = NSImage(systemSymbolName: "play.rectangle",
                                         accessibilityDescription: "View Screen")
        viewScreenButton.imagePosition = .imageLeading
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
        displaySize = header.displaySize
        displayOrientation = Int(header.displayOrientation)
        orientationCorrection = Int(header.displayOrientationCorrection)
        isRoundDisplay = header.isDisplayRound && header.displayWidth == header.displayHeight
        if isGated { isGated = false }
    }

    func reset() {
        isGated = true
        videoSize = .zero
        displaySize = .zero
        displayOrientation = 0
        orientationCorrection = 0
        control = nil
        displayLayer.flushAndRemoveImage()
        needsLayout = true
    }

    // MARK: - geometry

    /// The display as the picture presents it.
    private var rotatedDisplaySize: CGSize {
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
        let inset: CGFloat = 12
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
        let display = rotatedDisplaySize
        guard frameW > 0, frameH > 0, display.width > 0 else { return (frameH, 0) }
        let imageHeight = min((frameW * display.height / display.width).rounded(), frameH)
        return (imageHeight, ((frameH - imageHeight) / 2).rounded())
    }

    override func layout() {
        super.layout()
        let rect = displayRect()

        CATransaction.begin()
        CATransaction.setDisableActions(true)     // no interpolation: this resizes with the pane

        clipLayer.frame = rect
        clipLayer.cornerRadius = isRoundDisplay ? rect.width / 2 : min(12, rect.width * 0.04)
        clipLayer.borderWidth = isGated ? max(1, rect.width * 0.05) : 1
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
            : CATransform3DMakeRotation(CGFloat(orientationCorrection) * .pi / 2, 0, 0, 1)

        guard !isGated, videoSize.width > 0, videoSize.height > 0 else {
            displayLayer.frame = clipLayer.bounds
            CATransaction.commit()
            return
        }

        // Scale the coded frame so its live band exactly fills clipLayer, and push the top black
        // strip up out of the clip.
        let band = liveBand
        let scale = rect.width / videoSize.width
        displayLayer.frame = CGRect(x: 0, y: -band.startY * scale,
                                    width: videoSize.width * scale,
                                    height: videoSize.height * scale)
        CATransaction.commit()
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

        let quadrants = orientationCorrection % 2 == 0
            ? (displayOrientation + orientationCorrection) % 4
            : displayOrientation % 4
        let n: CGPoint
        switch ((quadrants % 4) + 4) % 4 {
        case 1:  n = CGPoint(x: 1 - fy, y: fx)
        case 2:  n = CGPoint(x: 1 - fx, y: 1 - fy)
        case 3:  n = CGPoint(x: fy, y: 1 - fx)
        default: n = CGPoint(x: fx, y: fy)
        }
        return CGPoint(x: (n.x * displaySize.width).rounded(),
                       y: (n.y * displaySize.height).rounded())
    }

    private func sendMotion(_ point: CGPoint, action: Int32) {
        guard let control else { return }
        let x = Int32(max(0, min(displaySize.width - 1, point.x)))
        let y = Int32(max(0, min(displaySize.height - 1, point.y)))
        control.send(ControlMessage.motionEvent(
            pointers: action == MotionAction.up ? [] : [.init(x: x, y: y)],
            action: action))
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard control != nil else { onViewScreen?(); return }
        guard let p = devicePoint(convert(event.locationInWindow, from: nil)) else { return }
        sendMotion(p, action: MotionAction.down)
    }

    override func mouseDragged(with event: NSEvent) {
        // Every intermediate position is sent. A tap and a swipe are not distinguished here the
        // way they are on the iOS path: that engine takes a gesture, this one takes raw motion
        // events, so the device's own gesture detector decides — which is what makes flings and
        // long-presses work without any of it being modelled here.
        guard let p = devicePoint(convert(event.locationInWindow, from: nil)) else { return }
        sendMotion(p, action: MotionAction.move)
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = devicePoint(convert(event.locationInWindow, from: nil)) else { return }
        // MotionEventMessage carries no pointers on ACTION_UP — the agent uses the last known
        // position — but the coordinates are sent anyway for the move that precedes it.
        sendMotion(p, action: MotionAction.move)
        sendMotion(p, action: MotionAction.up)
    }

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

    private func apply() {
        let lit = isFocusedPanel && (window?.isKeyWindow ?? false)
        layer?.backgroundColor = (lit ? Self.active : Self.resting).cgColor
        contentTintColor = lit ? .white : .labelColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: lit ? NSColor.white : NSColor.labelColor,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
    }
}
