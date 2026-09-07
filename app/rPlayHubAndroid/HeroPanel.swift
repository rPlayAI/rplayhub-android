//
//  HeroPanel.swift
//  The inspector's Hero tab: compose a store-listing shot of the live mirror and export it as
//  PNGs at Play Store / App Store sizes, or record it as a video with the phone slowly turning.
//
//  The panel owns a HeroComposer on a private serial queue and shows a live preview of what
//  the export will be. Every control edits a HeroStyle, which is saved as you go.
//

import AppKit
import CoreVideo

final class HeroPanel: NSView {
    /// The newest decoded frame of the mirrored display, from AppDelegate's stage sink.
    var frameSource: (() -> CVPixelBuffer?)?
    /// The mirrored display's canonical (portrait) pixel size, for the phone's proportions.
    var displaySizeSource: (() -> CGSize?)?
    /// Where sheets go.
    var hostWindow: (() -> NSWindow?)?
    /// A one-line status for the window subtitle.
    var onStatus: ((String) -> Void)?

    private(set) var style = HeroStyle.load()
    /// The mirrored device, for the clean status bar (SystemUI demo mode over adb).
    var serial: String?

    private let queue = DispatchQueue(label: "rplayhub.hero", qos: .userInitiated)
    private var composer: HeroComposer?             // queue-owned
    private var composerSize: CGSize = .zero        // queue-owned
    private let quadrantsLock = NSLock()
    private var quadrants = 0

    // Recording.
    private let recorder = FrameRecorder()
    private var recordTimer: DispatchSourceTimer?
    private var recordStart: CFTimeInterval = 0
    private var recordFrames = 0
    var isRecording: Bool { recordTimer != nil }

    // Preview.
    private let preview = NSImageView()
    private var previewTimer: Timer?
    private var previewPending: DispatchWorkItem?
    private var previewBusy = false

    // Controls.
    private let headline = NSTextField()
    private let accentLine = NSTextField()
    private let brand = NSTextField()
    private let accentWell = NSColorWell()
    private let accentPick = NSButton()
    private let cleanSwitch = NSSwitch()
    private let badgeSwitch = NSSwitch()
    private var sliders: [Slider: NSSlider] = [:]
    private let sizePopup = NSPopUpButton()
    private let finishPopup = NSPopUpButton()
    private let motionPopup = NSPopUpButton()
    private let exportButton = NSButton(title: "Export PNG…", target: nil, action: nil)
    private let packButton = NSButton(title: "Export Pack…", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record Video…", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")

    private enum Slider: Int, CaseIterable {
        case pitch, yaw, roll, scale, offsetX, offsetY
        var label: String {
            switch self {
            case .pitch: return "Tilt"
            case .yaw: return "Turn"
            case .roll: return "Lean"
            case .scale: return "Size"
            case .offsetX: return "Across"
            case .offsetY: return "Down"
            }
        }
        var range: ClosedRange<Double> {
            switch self {
            case .pitch: return -45...45
            case .yaw: return -60...60
            case .roll: return -45...45
            case .scale: return 0.5...2.2
            case .offsetX: return -0.7...0.7
            case .offsetY: return -0.9...0.5
            }
        }
    }

    private enum Motion: Int, CaseIterable {
        case still, orbit, sway
        var title: String {
            switch self {
            case .still: return "Still"
            case .orbit: return "Slow orbit"
            case .sway: return "Gentle sway"
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isHidden: Bool {
        didSet { isHidden ? stopPreview() : startPreview() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isHidden { startPreview() } else { stopPreview() }
    }

    /// Main thread, on geometry changes: the same quarter-turn bookkeeping as the twin.
    func apply(header: VideoPacketHeader) {
        let q = (Int(header.displayOrientation) - Int(header.displayOrientationCorrection) + 4) % 4
        quadrantsLock.lock()
        quadrants = q
        quadrantsLock.unlock()
    }

    // MARK: - build

    private func build() {
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 16.0 / 9.0).isActive = true
        // The image is rendered at the view's pixel size; it must never push the pane wider,
        // or every render would grow the pane and the next render with it.
        preview.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        preview.setContentCompressionResistancePriority(.init(1), for: .vertical)
        preview.setContentHuggingPriority(.init(1), for: .horizontal)
        preview.setContentHuggingPriority(.init(1), for: .vertical)

        func field(_ tf: NSTextField, _ placeholder: String, _ value: String) {
            tf.placeholderString = placeholder
            tf.stringValue = value
            tf.font = .systemFont(ofSize: 11)
            tf.controlSize = .small
            tf.target = self
            tf.action = #selector(textChanged(_:))
            tf.delegate = self
        }
        field(headline, "Headline — use / for a line break", style.headline.replacingOccurrences(of: "\n", with: " / "))
        field(accentLine, "Accent line", style.accentLine)
        field(brand, "Brand", style.brand)

        accentWell.color = style.accent.color
        accentWell.target = self
        accentWell.action = #selector(accentChanged)
        accentWell.controlSize = .small
        accentWell.translatesAutoresizingMaskIntoConstraints = false
        accentWell.widthAnchor.constraint(equalToConstant: 40).isActive = true

        accentPick.bezelStyle = .accessoryBarAction
        accentPick.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Accent from screen")
        accentPick.toolTip = "Pick the accent colour from the screen"
        accentPick.target = self
        accentPick.action = #selector(pickAccent)
        let accentTrailing = NSStackView(views: [accentPick, accentWell])
        accentTrailing.orientation = .horizontal
        accentTrailing.spacing = 2

        cleanSwitch.controlSize = .mini
        cleanSwitch.state = UserDefaults.standard.object(forKey: "HeroCleanStatusBar") == nil
            || UserDefaults.standard.bool(forKey: "HeroCleanStatusBar") ? .on : .off
        cleanSwitch.target = self
        cleanSwitch.action = #selector(cleanChanged)

        badgeSwitch.controlSize = .mini
        badgeSwitch.state = style.showBadge ? .on : .off
        badgeSwitch.target = self
        badgeSwitch.action = #selector(badgeChanged)

        var rows: [NSView] = [preview,
                              labelled("Headline", headline),
                              labelled("Accent", accentLine, trailing: accentTrailing),
                              labelled("Brand", brand, trailing: badgeSwitch)]

        for which in Slider.allCases {
            let slider = NSSlider(value: currentValue(which), minValue: which.range.lowerBound,
                                  maxValue: which.range.upperBound, target: self, action: #selector(sliderChanged(_:)))
            slider.tag = which.rawValue
            slider.controlSize = .mini
            slider.isContinuous = true
            sliders[which] = slider
            rows.append(labelled(which.label, slider))
        }

        sizePopup.controlSize = .small
        sizePopup.font = .systemFont(ofSize: 11)
        for size in HeroSize.all { sizePopup.addItem(withTitle: size.title) }
        sizePopup.selectItem(at: min(UserDefaults.standard.integer(forKey: "HeroSizeIndex"), HeroSize.all.count - 1))
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        finishPopup.controlSize = .small
        finishPopup.font = .systemFont(ofSize: 11)
        for f in HeroFinish.allCases { finishPopup.addItem(withTitle: f.title) }
        finishPopup.selectItem(at: HeroFinish.allCases.firstIndex(of: style.finish) ?? 0)
        finishPopup.target = self
        finishPopup.action = #selector(finishChanged)
        rows.append(labelled("Finish", finishPopup))

        rows.append(labelled("Output", sizePopup))

        motionPopup.controlSize = .small
        motionPopup.font = .systemFont(ofSize: 11)
        for motion in Motion.allCases { motionPopup.addItem(withTitle: motion.title) }
        motionPopup.selectItem(at: UserDefaults.standard.integer(forKey: "HeroMotion"))
        motionPopup.target = self
        motionPopup.action = #selector(motionChanged)
        rows.append(labelled("Motion", motionPopup))

        // 12:30, full battery, full Wi-Fi, no notifications — SystemUI demo mode for the shot.
        let cleanLabel = NSTextField(labelWithString: "Clean status bar for the shot")
        cleanLabel.font = .systemFont(ofSize: 11)
        rows.append(labelled("Status", cleanLabel, trailing: cleanSwitch))

        for (button, action) in [(exportButton, #selector(exportOne)), (packButton, #selector(exportPack)),
                                 (recordButton, #selector(toggleRecord))] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [exportButton, packButton, recordButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        rows.append(buttons)

        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        rows.append(status)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A scroll view so a short window still reaches the buttons. The document view is
        // flipped so the content hangs from the top instead of pooling at the bottom.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A label on the left, the control filling the rest, an optional trailing accessory.
    private func labelled(_ title: String, _ control: NSView, trailing: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        var views: [NSView] = [label, control]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        control.setContentHuggingPriority(.init(100), for: .horizontal)
        return row
    }

    private func currentValue(_ which: Slider) -> Double {
        switch which {
        case .pitch: return style.pitch
        case .yaw: return style.yaw
        case .roll: return style.roll
        case .scale: return style.scale
        case .offsetX: return style.offsetX
        case .offsetY: return style.offsetY
        }
    }

    private var selectedSize: HeroSize { HeroSize.all[max(sizePopup.indexOfSelectedItem, 0)] }
    private var selectedMotion: Motion { Motion(rawValue: motionPopup.indexOfSelectedItem) ?? .still }

    // MARK: - control actions

    @objc private func textChanged(_ sender: NSTextField) { readFields() }

    @objc private func accentChanged() {
        style.accent = HeroStyle.RGBA(accentWell.color)
        styleChanged()
    }

    @objc private func cleanChanged() {
        UserDefaults.standard.set(cleanSwitch.state == .on, forKey: "HeroCleanStatusBar")
    }

    @objc private func pickAccent() {
        let frame = frameSource?()
        let displaySize = displaySizeSource?() ?? CGSize(width: 1080, height: 2400)
        queue.async { [weak self] in
            guard let self else { return }
            if self.composer == nil || self.composerSize != displaySize || self.composer?.finish != self.style.finish {
                self.composer = HeroComposer(displaySize: displaySize, finish: self.style.finish)
                self.composerSize = displaySize
            }
            if let frame { self.composer?.setFrame(frame) }
            let color = self.composer?.sampleAccent()
            DispatchQueue.main.async {
                guard let color else { self.status.stringValue = "No vivid colour on the screen to take"; return }
                self.accentWell.color = color
                self.style.accent = HeroStyle.RGBA(color)
                self.styleChanged()
            }
        }
    }

    // MARK: - clean status bar (SystemUI demo mode)

    private var demoActive = false
    private var wantsCleanBar: Bool { cleanSwitch.state == .on && serial != nil }

    /// Put SystemUI in demo mode, wait for a fresh frame, then run `body`. Without a device or
    /// with the switch off, `body` runs at once.
    private func withCleanStatusBar(_ body: @escaping () -> Void) {
        guard wantsCleanBar, let serial else { body(); return }
        demoActive = true
        status.stringValue = "Setting the status bar…"
        DispatchQueue.global(qos: .userInitiated).async {
            let commands = [
                "settings put global sysui_demo_allowed 1",
                "am broadcast -a com.android.systemui.demo -e command enter",
                "am broadcast -a com.android.systemui.demo -e command clock -e hhmm 1230",
                "am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false",
                "am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4",
                "am broadcast -a com.android.systemui.demo -e command notifications -e visible false",
                "am broadcast -a com.android.systemui.demo -e command status -e volume hide -e bluetooth hide -e location hide -e alarm hide -e mute hide",
            ].joined(separator: "; ")
            _ = try? Adb.shell(serial, commands)
            AppBuild.log("hero: status bar demo mode on")
            // SystemUI redraws the bar, the agent encodes it, the decoder hands it over: give
            // that a moment so the frame taken is the clean one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: body)
        }
    }

    private func endCleanStatusBar() {
        guard demoActive, let serial else { return }
        demoActive = false
        DispatchQueue.global(qos: .utility).async {
            _ = try? Adb.shell(serial, "am broadcast -a com.android.systemui.demo -e command exit")
            AppBuild.log("hero: status bar demo mode off")
        }
    }

    @objc private func badgeChanged() {
        style.showBadge = badgeSwitch.state == .on
        styleChanged()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let which = Slider(rawValue: sender.tag) else { return }
        let v = sender.doubleValue
        switch which {
        case .pitch: style.pitch = v
        case .yaw: style.yaw = v
        case .roll: style.roll = v
        case .scale: style.scale = v
        case .offsetX: style.offsetX = v
        case .offsetY: style.offsetY = v
        }
        styleChanged()
    }

    @objc private func finishChanged() {
        style.finish = HeroFinish.allCases[max(finishPopup.indexOfSelectedItem, 0)]
        styleChanged()
    }

    @objc private func sizeChanged() {
        UserDefaults.standard.set(sizePopup.indexOfSelectedItem, forKey: "HeroSizeIndex")
        schedulePreview()
    }

    @objc private func motionChanged() {
        UserDefaults.standard.set(motionPopup.indexOfSelectedItem, forKey: "HeroMotion")
    }

    private func readFields() {
        style.headline = headline.stringValue
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        style.accentLine = accentLine.stringValue
        style.brand = brand.stringValue
        styleChanged()
    }

    private func styleChanged() {
        style.save()
        schedulePreview()
    }

    // MARK: - preview

    private func startPreview() {
        guard previewTimer == nil else { return }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.schedulePreview()
        }
        schedulePreview()
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    /// Debounced: a slider drag asks many times a second, the render happens once it settles.
    private func schedulePreview() {
        previewPending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderPreview() }
        previewPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Dev hook: RPLAYHUB_HERO_DUMP=<path.png> writes one full-size render as soon as a live
    /// frame is on the panel, so the output can be checked without driving the save sheet.
    private var dumpDone = false
    private var dumpMP4Done = false

    private func renderPreview() {
        guard !previewBusy, !isRecording else { return }
        let frame = frameSource?()
        if !dumpDone, frame != nil, let path = ProcessInfo.processInfo.environment["RPLAYHUB_HERO_DUMP"], !path.isEmpty {
            dumpDone = true
            withCleanStatusBar { [weak self] in
                guard let self else { return }
                self.write(sizes: [(self.selectedSize, URL(fileURLWithPath: path))])
            }
        }
        // And RPLAYHUB_HERO_DUMP_MP4=<path.mp4> records four seconds of the orbit the same way.
        if !dumpMP4Done, frame != nil, let path = ProcessInfo.processInfo.environment["RPLAYHUB_HERO_DUMP_MP4"], !path.isEmpty {
            dumpMP4Done = true
            motionPopup.selectItem(at: Motion.orbit.rawValue)
            startRecording(to: URL(fileURLWithPath: path), size: selectedSize)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.stopRecording() }
        }
        let displaySize = displaySizeSource?() ?? CGSize(width: 1080, height: 2400)
        let style = self.style
        // Render at the preview's own pixel size (Retina included) so its edges are as sharp
        // as the export's; a quarter-size render scaled up read as blur.
        let target = selectedSize.size
        let scale = window?.backingScaleFactor ?? 2
        let fitWidth = min(max(preview.bounds.width, 120) * scale, 1200)
        let previewSize = CGSize(width: fitWidth.rounded(), height: (fitWidth * target.height / target.width).rounded())
        previewBusy = true
        queue.async { [weak self] in
            guard let self else { return }
            let image = self.compose(frame: frame, displaySize: displaySize, size: previewSize, style: style, pose: nil)
            DispatchQueue.main.async {
                self.previewBusy = false
                if let image {
                    // Sized in points to the view, so a Retina render is Retina-sharp, not 2x big.
                    let points = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                    self.preview.image = NSImage(cgImage: image, size: points)
                }
                if frame == nil { self.status.stringValue = "Start mirroring to put a live screen on the phone" }
                else if self.status.stringValue.hasPrefix("Start mirroring") { self.status.stringValue = "" }
            }
        }
    }

    /// Queue only. Keeps one composer per display size and paints the newest frame before rendering.
    private func compose(frame: CVPixelBuffer?, displaySize: CGSize, size: CGSize, style: HeroStyle,
                         pose: HeroComposer.Pose?, supersample: Bool = true) -> CGImage? {
        if composer == nil || composerSize != displaySize || composer?.finish != style.finish {
            composer = HeroComposer(displaySize: displaySize, finish: style.finish)
            composerSize = displaySize
        }
        guard let composer else { return nil }
        quadrantsLock.lock()
        let q = quadrants
        quadrantsLock.unlock()
        composer.setQuadrants(q)
        if let frame { composer.setFrame(frame) }
        return composer.render(size: size, style: style, pose: pose, supersample: supersample)
    }

    // MARK: - export

    @objc func exportOne() {
        guard let host = hostWindow?() else { return }
        let target = selectedSize
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(brandSlug)-\(target.filename)"
        panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: host) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.withCleanStatusBar { self.write(sizes: [(target, url)]) }
        }
    }

    /// The fancy screenshot from the camera button: the current look at the chosen size.
    func export(to url: URL) {
        withCleanStatusBar { [weak self] in
            guard let self else { return }
            self.write(sizes: [(self.selectedSize, url)])
        }
    }

    @objc func exportPack() {
        guard let host = hostWindow?() else { return }
        let platform = selectedSize.platform
        let sizes = HeroSize.all.filter { $0.platform == platform }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export \(sizes.count) PNGs"
        panel.message = "Choose a folder for the \(platform) pack."
        panel.beginSheetModal(for: host) { [weak self] response in
            guard let self, response == .OK, let dir = panel.url else { return }
            self.withCleanStatusBar {
                self.write(sizes: sizes.map { ($0, dir.appendingPathComponent("\(self.brandSlug)-\($0.filename).png")) })
            }
        }
    }

    private var brandSlug: String {
        let slug = style.brand.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "hero" : slug
    }

    private func write(sizes: [(HeroSize, URL)]) {
        let frame = frameSource?()
        let displaySize = displaySizeSource?() ?? CGSize(width: 1080, height: 2400)
        let style = self.style
        status.stringValue = "Rendering…"
        queue.async { [weak self] in
            guard let self else { return }
            var written = 0, failed: String?
            for (size, url) in sizes {
                if let image = self.compose(frame: frame, displaySize: displaySize, size: size.size, style: style, pose: nil) {
                    do { try HeroComposer.writePNG(image, to: url); written += 1 }
                    catch { failed = error.localizedDescription }
                } else { failed = "render failed at \(size.width)×\(size.height)" }
            }
            let last = sizes.last?.1
            DispatchQueue.main.async {
                if let failed {
                    self.status.stringValue = failed
                } else {
                    self.status.stringValue = written == 1 ? "Saved \(last?.lastPathComponent ?? "")" : "Saved \(written) PNGs"
                    self.onStatus?(self.status.stringValue)
                }
                AppBuild.log("hero: \(self.status.stringValue)")
                self.endCleanStatusBar()
            }
        }
    }

    // MARK: - recording

    @objc func toggleRecord() {
        if isRecording { stopRecording(); return }
        guard let host = hostWindow?() else { return }
        let target = selectedSize
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(brandSlug)-hero-\(target.width)x\(target.height)"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.beginSheetModal(for: host) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.withCleanStatusBar { self.startRecording(to: url, size: target) }
        }
    }

    private func startRecording(to url: URL, size: HeroSize) {
        stopPreview()
        recorder.start(to: url, width: size.width, height: size.height)
        recordStart = CACurrentMediaTime()
        recordFrames = 0
        recordButton.title = "Stop"
        status.stringValue = "Recording…"
        onStatus?("recording hero video")
        AppBuild.log("hero: recording started (\(size.width)×\(size.height))")

        let motion = selectedMotion
        let style = self.style
        let displaySize = displaySizeSource?() ?? CGSize(width: 1080, height: 2400)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = CACurrentMediaTime() - self.recordStart
            let frame = self.frameSource?()
            let pose = Self.pose(for: motion, style: style, at: t)
            guard let image = self.compose(frame: frame, displaySize: displaySize, size: size.size, style: style, pose: pose,
                                           supersample: false),
                  let buffer = HeroComposer.pixelBuffer(from: image) else { return }
            self.recorder.append(buffer)
            self.recordFrames += 1
            if self.recordFrames % 30 == 0 {
                let seconds = Int(t)
                DispatchQueue.main.async { self.status.stringValue = "Recording… \(seconds)s" }
            }
        }
        recordTimer = timer
        timer.resume()
    }

    private func stopRecording() {
        recordTimer?.cancel()
        recordTimer = nil
        endCleanStatusBar()
        recordButton.title = "Record Video…"
        recorder.stop { [weak self] url in
            guard let self else { return }
            self.status.stringValue = url != nil ? "Saved \(url!.lastPathComponent)" : "Recording failed"
            self.onStatus?(self.status.stringValue)
            AppBuild.log("hero: \(self.status.stringValue)")
            if !self.isHidden { self.startPreview() }
        }
    }

    /// The phone's pose `t` seconds into a recording: a slow figure around the hero angle.
    private static func pose(for motion: Motion, style: HeroStyle, at t: Double) -> HeroComposer.Pose? {
        switch motion {
        case .still:
            return nil
        case .orbit:
            return HeroComposer.Pose(pitch: style.pitch + 6 * sin(t * 0.45),
                                     yaw: style.yaw + 16 * sin(t * 0.6),
                                     roll: style.roll + 4 * sin(t * 0.3))
        case .sway:
            return HeroComposer.Pose(pitch: style.pitch + 2.5 * sin(t * 0.7),
                                     yaw: style.yaw + 6 * sin(t * 0.5),
                                     roll: style.roll + 1.5 * sin(t * 0.4))
        }
    }
}

extension HeroPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { readFields() }
}
