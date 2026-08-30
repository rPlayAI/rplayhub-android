//
//  AppDelegate.swift
//  The window: device sidebar, live screen, inspector — Device Hub's three panes.
//
//  Adopted from ~/rplay-hub, with the engine connection replaced by an AgentSession. There is no
//  second process to wait for here: adb needs no privilege, so the app deploys and launches the
//  agent itself. What used to be "retrying the engine every two seconds" is now a poll of
//  `adb devices`, which is also how a device appearing mid-session shows up in the sidebar.
//

import AppKit
import simd

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var splitView: NSSplitView!
    private let sidebar = DeviceSidebar()
    private let mirror = MirrorView()
    private let strip = ControlStrip()
    private let inspector = InspectorPane()
    private let screenWindow = ScreenWindow()
    private var stage: NSView!

    private var session: AgentSession?
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var propertiesForSerial: String?

    /// Auto-reconnect bookkeeping. A session that dies after reaching `.running` — a protocol
    /// desync, or the agent exiting mid-stream — is restarted rather than reported: the agent is
    /// stateless and the deploy takes seconds. Windowed so a persistent failure surfaces as an
    /// error instead of looping silently.
    private var sessionReachedRunning = false
    private var reconnectAttempts = 0
    private var reconnectWindowStart: Date?

    /// Created on first use and kept: the decode thread's frame tee reads this property, and a
    /// stable instance (gated inside by its own `isActive` lock) keeps that access race-free.
    private var twin: TwinView?
    private var twinActive = false
    private var twinGateItem: NSMenuItem?
    private var twinOpenItem: NSMenuItem?
    private var screenOffItem: NSMenuItem?

    /// What we ask the agent to cap the encode at. Well above any display we will show it on, so
    /// the picture is never the limiting factor; the agent scales down to the device's own size
    /// anyway.
    private let maxVideoSize = CGSize(width: 1920, height: 1920)

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppBuild.log("rPlayHubAndroid \(AppBuild.version) starting")
        buildMenu()
        buildWindow()
        startPolling()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    // MARK: - window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                          // No .fullSizeContentView: it extends the content view under the
                          // title bar, which hid the top of the mirrored screen behind it.
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "rPlayHub — Android"
        window.setFrameAutosaveName("MainWindow")
        window.center()

        // Middle pane: the picture with its button strip underneath, as one unit, so
        // "Open in New Window" moves both.
        mirror.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        let middle = NSView()
        middle.addSubview(mirror)
        middle.addSubview(strip)
        NSLayoutConstraint.activate([
            mirror.topAnchor.constraint(equalTo: middle.topAnchor, constant: 16),
            mirror.leadingAnchor.constraint(equalTo: middle.leadingAnchor, constant: 12),
            mirror.trailingAnchor.constraint(equalTo: middle.trailingAnchor, constant: -12),
            strip.topAnchor.constraint(equalTo: mirror.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            strip.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
        stage = middle

        splitView = PaneSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(middle)
        splitView.addArrangedSubview(inspector)

        // The middle pane holds the LOWEST priority, so it is the one that gives when something
        // else needs room. Both side panes hold harder than it does.
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 2)

        // Without explicit widths the split view squeezes the side panes to nothing — the sidebar
        // collapsed to a ~20pt sliver showing "Av", and the inspector wrapped one character per
        // line. setPosition() alone does not survive layout, because a pane with no intrinsic
        // width has nothing to hold on to. Resting width at a middling priority, plus a hard
        // minimum, is what ~/rplay-hub arrived at for the same failure.
        for (pane, width) in [(sidebar as NSView, 210.0), (middle as NSView, 429.0),
                              (inspector as NSView, 320.0)] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            let resting = pane.widthAnchor.constraint(equalToConstant: width)
            resting.priority = NSLayoutConstraint.Priority(700)
            resting.isActive = true
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: width - 60).isActive = true
        }

        // A soft shadow cast outward from each side pane, in place of a divider line — the same
        // separation Device Hub draws between its columns.
        for (pane, dx) in [(sidebar as NSView, CGFloat(2)), (inspector as NSView, CGFloat(-2))] {
            pane.wantsLayer = true
            pane.layer?.masksToBounds = false
            pane.shadow = NSShadow()
            pane.layer?.shadowColor = NSColor.black.cgColor
            pane.layer?.shadowOpacity = 0.07
            pane.layer?.shadowRadius = 9
            pane.layer?.shadowOffset = CGSize(width: dx, height: 0)
        }

        window.contentView = splitView
        window.setContentSize(NSSize(width: 1000, height: 760))

        buildToolbar()

        wireUp()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The title bar, split into three sections that follow the split view's own dividers.
    ///
    /// Device Hub's title bar is not one continuous strip: each column gets its own section, so
    /// the sidebar's toolbar area reads as part of the sidebar and the inspector's as part of the
    /// inspector. NSTrackingSeparatorToolbarItem is what does that — it follows a divider as the
    /// panes resize.
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        window.titlebarAppearsTransparent = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // The app name and the device name are both toolbar items now; leaving the standard
        // centred title visible would put a second copy of roughly the same text in the row.
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
    }

    private func wireUp() {
        sidebar.onSelect = { [weak self] device in self?.selectionChanged(device) }
        sidebar.onMirror = { [weak self] device in self?.startSession(for: device) }
        mirror.onViewScreen = { [weak self] in
            guard let self else { return }
            // Fall back to the only device there is. Requiring a selection when there is
            // nothing to choose between is friction for its own sake.
            let ready = self.sidebar.devices.filter { $0.isReady }
            guard let device = self.sidebar.selected ?? (ready.count == 1 ? ready.first : nil) else {
                self.present(message: "No device selected",
                             detail: ready.isEmpty
                                 ? "No device is ready for adb. Check the sidebar for why."
                                 : "Pick one of the \(ready.count) devices in the sidebar first.")
                return
            }
            self.startSession(for: device)
        }
        strip.onAction = { [weak self] action in self?.perform(action) }
        mirror.onCommand = { [weak self] command in self?.perform(command) }
        mirror.onFilesDropped = { [weak self] urls in self?.handleDroppedFiles(urls) }
        // The device commands move from the mirror pane to the device's row in the sidebar.
        if let commands = mirror.commandMenu { sidebar.appendDeviceCommands(from: commands) }
    }

    // MARK: - devices

    private func startPolling() {
        refreshDevices()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshDevices()
        }
    }

    private func refreshDevices() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var devices: [AdbDevice] = []
            var note = ""
            do {
                let version = try Adb.serverVersion()
                devices = try Adb.devices()
                note = devices.isEmpty
                    ? "adb server \(version) — no devices"
                    : "adb server \(version) — \(devices.count) device\(devices.count == 1 ? "" : "s")"
            } catch {
                note = "\(error)"
            }
            let captured = (devices, note)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sidebar.update(devices: captured.0, note: captured.1)
                // Nothing to choose between: select it, so the inspector has a device rather
                // than showing "No device selected" beside a list of exactly one.
                if self.sidebar.selected == nil {
                    let ready = captured.0.filter { $0.isReady }
                    if ready.count == 1 { self.sidebar.select(serial: ready[0].serial) }
                }
            }
        }
    }

    private func selectionChanged(_ device: AdbDevice?) {
        guard let device else {
            inspector.serial = nil
            mirror.deviceName = nil
            mirror.deviceSubtitle = nil
            deviceTitleName.stringValue = "No device"
            deviceTitleDetail.stringValue = ""
            return
        }
        window.title = "rPlayHub — \(device.displayName)"
        deviceTitleName.stringValue = device.displayName
        deviceTitleDetail.stringValue = device.isReady ? device.serial : device.state
        mirror.deviceName = device.displayName
        mirror.deviceSubtitle = device.isReady ? device.serial : device.state
        inspector.serial = device.isReady ? device.serial : nil
        guard device.isReady, propertiesForSerial != device.serial else { return }
        propertiesForSerial = device.serial
        loadAndroidVersion(device)
    }

    /// Just for the label under the idle mockup; the Info tab loads the rest itself.
    private func loadAndroidVersion(_ device: AdbDevice) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let release = (try? Adb.getprop(device.serial, "ro.build.version.release")) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard self?.propertiesForSerial == device.serial, !release.isEmpty else { return }
                self?.mirror.deviceSubtitle = "Android \(release)"
                self?.deviceTitleDetail.stringValue = "Android \(release)"
            }
        }
    }

    // MARK: - session

    private func startSession(for device: AdbDevice) {
        guard device.isReady else {
            present(message: "\(device.displayName) is \(device.state)",
                    detail: device.state == "unauthorized"
                        ? "Accept the USB debugging prompt on the device, then try again."
                        : "The device is not ready for adb commands.")
            return
        }
        if twinActive { exitTwin() }   // the new session's decoder starts back in native output
        session?.stop()
        mirror.reset()
        strip.setSessionActive(false)
        sessionReachedRunning = false

        let s = AgentSession(serial: device.serial)
        session = s
        s.onState = { [weak self] state in self?.sessionStateChanged(state) }
        s.onAgentLog = { line in AppBuild.log("agent: \(line)") }
        s.decoder.onFrame = { [weak self] picture in
            guard let self else { return }
            self.mirror.displayLayer.present(picture)
            self.twin?.present(picture)   // one lock and out when the mode is off
        }
        s.start(maxVideoSize: maxVideoSize)
    }

    private func sessionStateChanged(_ state: AgentSession.State) {
        switch state {
        case .idle:
            window.subtitle = ""
            strip.setSessionActive(false)
        case .deploying(let step):
            window.subtitle = step
        case .running:
            window.subtitle = "mirroring"
            strip.setSessionActive(true)
            sessionReachedRunning = true
            attachStream()
            startHealthTimer()
        case .failed(let reason):
            window.subtitle = "failed"
            strip.setSessionActive(false)
            mirror.reset()
            // Dying mid-stream is recoverable — the agent exiting is how it now reports an
            // unrecoverable socket (a write timeout leaves a packet half-sent). Failing to
            // come up at all is not; that stays an error.
            if sessionReachedRunning {
                sessionReachedRunning = false
                autoReconnect(after: reason)
            } else {
                present(message: "Mirroring failed", detail: reason)
            }
        }
    }

    /// Restart the session on the same device, at most three times a minute. Past that the
    /// failure is not transient, and it surfaces the way it did before auto-reconnect existed.
    private func autoReconnect(after reason: String) {
        guard let serial = session?.serial else { return }
        let now = Date()
        if let start = reconnectWindowStart, now.timeIntervalSince(start) < 60 {
            reconnectAttempts += 1
        } else {
            reconnectWindowStart = now
            reconnectAttempts = 1
        }
        guard reconnectAttempts <= 3 else {
            present(message: "Mirroring keeps failing", detail: reason)
            return
        }
        guard let device = sidebar.devices.first(where: { $0.serial == serial }), device.isReady else {
            present(message: "Mirroring ended", detail: reason)
            return
        }
        AppBuild.log("reconnecting to \(serial) (attempt \(reconnectAttempts)): \(reason)")
        window.subtitle = "reconnecting"
        startSession(for: device)
    }

    private func attachStream() {
        guard let session, let video = session.video else { return }
        mirror.control = session.control
        loadDisplayShape(session.serial)
        video.onFormat = { [weak self] size in self?.mirror.videoSize = size }
        video.onGeometry = { [weak self] header in
            self?.mirror.apply(header: header)
            self?.twin?.apply(header: header)
        }
        // Both closures check the stream is still the current one: after a reconnect, a stale
        // stream's last gasp arrives on the main queue behind the new session's startup and
        // must not tear it down.
        video.onDisconnect = { [weak self, weak video] reason in
            guard let self, video != nil, self.session?.video === video else { return }
            AppBuild.log("video: \(reason)")
            self.strip.setSessionActive(false)
        }
        video.onDesync = { [weak self, weak video] reason in
            guard let self, video != nil, self.session?.video === video else { return }
            AppBuild.log("video: \(reason)")
            self.autoReconnect(after: reason)
        }
    }

    /// The screen's physical outline — rounded corners and the camera hole. One dumpsys call,
    /// off the main queue, once per session; it cannot change while the device is plugged in.
    private func loadDisplayShape(_ serial: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let shape = DisplayShape.query(serial: serial)
            DispatchQueue.main.async { [weak self] in
                guard self?.session?.serial == serial else { return }
                self?.mirror.displayShape = shape
                if let shape {
                    AppBuild.log("display shape: corner r=\(Int(shape.cornerRadius)) "
                                 + "cutout=\(shape.cutout.map { "\($0)" } ?? "none")")
                }
            }
        }
    }

    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateHealth()
        }
    }

    private func updateHealth() {
        guard let video = session?.video else { inspector.info.setHealth(""); return }
        let layer = mirror.displayLayer
        var lines = [
            "codec     \(video.advertisedCodec)",
            "packets   \(video.packetsReceived)",
            "bytes     \(video.bytesReceived / 1024) KiB",
            "decoded   \(video.framesDecoded)",
            "shown     \(layer.framesPresented)",
            "skipped   \(layer.framesSkipped)",
        ]
        if let header = video.lastHeader {
            lines.append("display   \(header.displayWidth)x\(header.displayHeight)")
            lines.append("rotation  \(header.displayOrientation)")
            lines.append("bitrate   \(header.bitRate / 1000) kbps"
                         + (header.isBitRateReduced ? " (reduced)" : ""))
        }
        if let sensor = session?.sensor {
            lines.append("gyro      \(sensor.packetsReceived) pkts")
        }
        if video.awaitingKeyframe {
            lines.append("waiting for a keyframe (\(video.framesBeforeKeyframe) dropped)")
        }
        if let error = video.lastError { lines.append("error     \(error)") }
        inspector.info.setHealth(lines.joined(separator: "\n"))
    }

    // MARK: - the screen's right-click menu

    private var isPinned = false
    private let deviceTitleName = NSTextField(labelWithString: "No device")
    private let deviceTitleDetail = NSTextField(labelWithString: "")

    /// Flip the twin gate. The menu entry follows immediately; the sensor channel is asked for
    /// at session start, so a running session needs a Reconnect before orientation flows.
    @objc private func openTwinFromMenu() {
        toggleTwin()
    }

    /// scrcpy's --turn-screen-off. The agent applies it at session start (and restores the panel
    /// when the session ends), so flipping it mid-session restarts the session with the new flag.
    @objc private func toggleScreenOff() {
        let key = "TurnScreenOffWhileMirroring"
        let enabled = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        screenOffItem?.state = enabled ? .on : .off
        AppBuild.log("turn screen off while mirroring: \(enabled)")
        if let session, sessionReachedRunning,
           let device = sidebar.devices.first(where: { $0.serial == session.serial }), device.isReady {
            startSession(for: device)
        }
    }

    @objc private func toggleTwinGate() {
        AppBuild.twinEnabled.toggle()
        let enabled = AppBuild.twinEnabled
        twinGateItem?.state = enabled ? .on : .off
        twinOpenItem?.isHidden = !enabled
        mirror.setTwinVisible(enabled)
        if !enabled, twinActive { exitTwin() }
        AppBuild.log("3D device twin \(enabled ? "enabled" : "disabled")")
        if enabled, session != nil, session?.sensor == nil {
            window.subtitle = "reconnect to feed the 3D twin orientation"
        }
    }

    /// Not a second viewer — a display mode. The 3D view takes the mirror's place in the middle
    /// pane; exiting puts the flat view back. One stream, one picture on screen.
    private func toggleTwin() {
        if twinActive { exitTwin(); return }
        guard AppBuild.twinEnabled else { return }
        guard let session, let video = session.video else {
            present(message: "No live session", detail: "Start mirroring first, then View in 3D.")
            return
        }
        // The twin's texture path wants BGRA; restart the video stream so the switch happens on
        // fresh parameter sets and a keyframe instead of mid-GOP.
        session.decoder.outputBGRA = true
        restartVideoStream()

        let tv = twin ?? {
            let created = TwinView()
            created.translatesAutoresizingMaskIntoConstraints = false
            twin = created
            return created
        }()
        if ProcessInfo.processInfo.environment["RPLAYHUB_FAKE_GYRO"] == "1" {
            // Scripted poses instead of the device, to verify the orientation math without a
            // hand on the phone: face-on, yaw left, tilt top toward the viewer, roll
            // counterclockwise, face-on again. 4 seconds each.
            let start = Date()
            tv.orientationSource = { Self.fakeGyro(Float(Date().timeIntervalSince(start))) }
            AppBuild.log("twin: using the fake scripted gyro")
        } else {
            tv.orientationSource = { [weak self] in self?.session?.sensor?.latest }
        }
        if tv.superview == nil {
            stage.addSubview(tv)
            NSLayoutConstraint.activate([
                tv.topAnchor.constraint(equalTo: mirror.topAnchor),
                tv.leadingAnchor.constraint(equalTo: mirror.leadingAnchor),
                tv.trailingAnchor.constraint(equalTo: mirror.trailingAnchor),
                tv.bottomAnchor.constraint(equalTo: mirror.bottomAnchor),
            ])
        }
        tv.isHidden = false
        mirror.isHidden = true
        tv.activate(displaySize: video.lastHeader?.displaySize ?? CGSize(width: 1080, height: 2400))
        if let header = video.lastHeader { tv.apply(header: header) }
        twinActive = true
        mirror.setTwinActive(true)
        twinOpenItem?.title = "Exit 3D View"
        if session.sensor == nil {
            AppBuild.log("twin: no sensor channel in this session — static pose until reconnect")
        }
    }

    /// The scripted test poses, in Android's East-North-Up convention. Base pose: upright, screen
    /// normal pointing South (at a viewer looking North). Each phase applies one world-frame
    /// rotation whose expected on-screen effect is written beside it.
    private static func fakeGyro(_ elapsed: Float) -> simd_quatf {
        let upright = simd_quatf(angle: .pi / 2, axis: simd_float3(1, 0, 0))  // flat → facing South
        let phase = Int(elapsed / 4) % 5
        switch phase {
        case 1:   // yaw +35° about Up — the twin should turn to the viewer's left
            return simd_quatf(angle: 35 * .pi / 180, axis: simd_float3(0, 0, 1)) * upright
        case 2:   // pitch +25° about East — the top should tilt toward the viewer
            return simd_quatf(angle: 25 * .pi / 180, axis: simd_float3(1, 0, 0)) * upright
        case 3:   // roll +30° about South (the facing axis) — counterclockwise on screen
            return simd_quatf(angle: 30 * .pi / 180, axis: simd_float3(0, -1, 0)) * upright
        default:  // face-on
            return upright
        }
    }

    private func exitTwin() {
        guard twinActive, let tv = twin else { return }
        tv.deactivate()
        tv.isHidden = true
        mirror.isHidden = false
        twinActive = false
        mirror.setTwinActive(false)
        twinOpenItem?.title = "View Screen in 3D"
        if let session {
            session.decoder.outputBGRA = false
            restartVideoStream()
        }
    }

    private func restartVideoStream() {
        guard let control = session?.control else { return }
        control.send(ControlMessage.stopVideoStream())
        control.send(ControlMessage.startVideoStream(width: Int32(maxVideoSize.width),
                                                     height: Int32(maxVideoSize.height)))
    }

    /// scrcpy's window behaviour: drop an APK to install it, drop anything else to put it in
    /// Download. Sequential on one background queue — two drops should not race adb.
    private func handleDroppedFiles(_ urls: [URL]) {
        guard let serial = session?.serial else { return }
        window.subtitle = "receiving \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            for url in urls {
                let name = url.lastPathComponent
                do {
                    if url.pathExtension.lowercased() == "apk" {
                        try Adb.install(serial, apkPath: url.path)
                        AppBuild.log("installed \(name)")
                    } else {
                        let remote = "/sdcard/Download/\(name)"
                        try Adb.push(serial, localPath: url.path, remotePath: remote)
                        // Make the file visible to apps right away rather than after a reboot.
                        _ = try? Adb.shell(serial, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://"
                                           + Adb.shellQuote(remote))
                        AppBuild.log("pushed \(name) to Download")
                    }
                } catch {
                    AppBuild.log("drop failed for \(name): \(error)")
                    failures.append(name)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window.subtitle = self.session != nil ? "mirroring" : ""
                if !failures.isEmpty {
                    self.present(message: "Could not transfer \(failures.joined(separator: ", "))",
                                 detail: "See the log for the adb error.")
                }
            }
        }
    }

    private func perform(_ command: MirrorView.Command) {
        switch command {
        case .twin:       toggleTwin()
        case .screenshot: saveScreenshot()
        case .record:     toggleRecording()
        case .home:       perform(ControlStrip.Action.home)
        case .back:       perform(ControlStrip.Action.back)
        case .recents:    perform(ControlStrip.Action.overview)
        case .rotate:     perform(ControlStrip.Action.rotate)
        case .power:      perform(ControlStrip.Action.power)
        case .wake:
            session?.control?.send(ControlMessage.keyEvent(action: KeyAction.downAndUp,
                                                           keycode: AndroidKey.wakeup))
        case .pin:
            isPinned.toggle()
            window.level = isPinned ? .floating : .normal
            mirror.setPinned(isPinned)
        case .openWindow:
            screenWindow.open(stage: stage, from: splitView, title: window.title, tabbedWith: nil)
        case .openTab:
            screenWindow.open(stage: stage, from: splitView, title: window.title,
                              tabbedWith: window)
        case .stop:
            stopMirroring()
        case .reconnect:
            if let device = sidebar.selected ?? sidebar.devices.first(where: { $0.isReady }) {
                startSession(for: device)
            }
        }
    }

    // MARK: - actions

    private func perform(_ action: ControlStrip.Action) {
        // Screenshot and record go over adb, not the control channel, so they are handled before
        // the guard that requires a live control connection.
        if action == .screenshot { saveScreenshot(); return }
        if action == .record { toggleRecording(); return }
        guard let control = session?.control else { return }
        switch action {
        case .back:
            control.send(ControlMessage.keyEvent(action: KeyAction.downAndUp,
                                                 keycode: AndroidKey.back))
        case .home:
            control.send(ControlMessage.keyEvent(action: KeyAction.downAndUp,
                                                 keycode: AndroidKey.home))
        case .overview:
            control.send(ControlMessage.keyEvent(action: KeyAction.downAndUp,
                                                 keycode: AndroidKey.appSwitch))
        case .volumeUp:
            control.send(ControlMessage.keyEvent(action: KeyAction.downAndUp,
                                                 keycode: AndroidKey.volumeUp))
        case .volumeDown:
            control.send(ControlMessage.keyEvent(action: KeyAction.downAndUp,
                                                 keycode: AndroidKey.volumeDown))
        case .power:
            control.send(ControlMessage.keyEvent(action: KeyAction.downAndUp,
                                                 keycode: AndroidKey.power))
        case .rotate:
            // Ask for the next quadrant explicitly. -1 would hand control back to the device's
            // own sensor, which is a different command and belongs on a menu, not this button.
            let next = Int32((mirror.displayOrientation + 1) % 4)
            control.send(ControlMessage.setDeviceOrientation(next))
        case .screenshot, .record:
            break               // handled above, before the control-connection guard
        }
    }

    /// Screenshots go through `screencap` rather than grabbing the decoded picture: the picture
    /// we have has been through a lossy encoder at whatever bit rate the agent settled on, and a
    /// screenshot is the one thing where that is visible.
    private func saveScreenshot() {
        guard let serial = session?.serial else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenshot.png"
        panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let remote = "/data/local/tmp/rplayhub-screenshot.png"
                    _ = try Adb.shell(serial, "screencap -p \(remote)")
                    // Pulled over sync:, not `cat` through exec:. Adb.shell decodes its output
                    // as UTF-8, which silently mangles every non-text byte — a PNG does not
                    // survive the round trip.
                    try Adb.pull(serial, remotePath: remote, localPath: url.path)
                    _ = try? Adb.shell(serial, "rm -f \(remote)")
                    AppBuild.log("screenshot saved to \(url.path)")
                } catch {
                    AppBuild.log("screenshot failed: \(error)")
                }
            }
        }
    }

    // MARK: - screen recording

    private var recordingSerial: String?
    private var recordingSocket: TCPSocket?
    private static let recordRemotePath = "/data/local/tmp/rplayhub-record.mp4"

    private func toggleRecording() {
        recordingSerial == nil ? startRecording() : stopRecording()
    }

    /// `screenrecord` writes on the device and is capped at three minutes by Android itself. The
    /// shell socket is held open for the duration: closing it is what would kill the process, and
    /// a killed screenrecord never writes its moov atom, leaving an unplayable file.
    private func startRecording() {
        guard let serial = session?.serial else { return }
        recordingSerial = serial
        strip.setRecording(true)
        mirror.setRecording(true)
        AppBuild.log("recording started")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let socket = try? Adb.shellStream(
                serial, "screenrecord --bit-rate 8000000 \(Self.recordRemotePath)")
            DispatchQueue.main.async {
                guard let self else { socket?.shutdownAndClose(); return }
                guard self.recordingSerial == serial else {
                    socket?.shutdownAndClose()      // stopped before the stream came up
                    return
                }
                self.recordingSocket = socket
            }
        }
    }

    private func stopRecording() {
        guard let serial = recordingSerial else { return }
        recordingSerial = nil
        strip.setRecording(false)
        mirror.setRecording(false)
        let socket = recordingSocket
        recordingSocket = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // SIGINT, not a socket close: screenrecord traps it and finalises the container.
            _ = try? Adb.shell(serial, "pkill -SIGINT screenrecord")
            Thread.sleep(forTimeInterval: 2)        // let it write the moov atom
            socket?.shutdownAndClose()

            DispatchQueue.main.async {
                guard let self else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "recording.mp4"
                panel.allowedContentTypes = [.mpeg4Movie]
                panel.beginSheetModal(for: self.window) { response in
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer {
                            _ = try? Adb.shell(serial, "rm -f \(Self.recordRemotePath)")
                        }
                        guard response == .OK, let url = panel.url else { return }
                        do {
                            try Adb.pull(serial, remotePath: Self.recordRemotePath,
                                         localPath: url.path)
                            AppBuild.log("recording saved to \(url.path)")
                        } catch {
                            AppBuild.log("recording failed: \(error)")
                        }
                    }
                }
            }
        }
    }

    private func present(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    // MARK: - menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About rPlayHub Android",
                        action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let deviceItem = NSMenuItem()
        let deviceMenu = NSMenu(title: "Device")
        deviceMenu.addItem(withTitle: "Mirror Selected", action: #selector(mirrorSelected),
                           keyEquivalent: "m").target = self
        deviceMenu.addItem(withTitle: "Stop Mirroring", action: #selector(stopMirroring),
                           keyEquivalent: ".").target = self
        deviceMenu.addItem(.separator())
        let screenOff = deviceMenu.addItem(withTitle: "Turn Screen Off While Mirroring",
                                           action: #selector(toggleScreenOff), keyEquivalent: "")
        screenOff.target = self
        screenOff.state = UserDefaults.standard.bool(forKey: "TurnScreenOffWhileMirroring")
            ? .on : .off
        screenOffItem = screenOff
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(withTitle: "Refresh Devices", action: #selector(refreshFromMenu),
                           keyEquivalent: "r").target = self
        deviceItem.submenu = deviceMenu
        main.addItem(deviceItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Open Screen in New Window",
                         action: #selector(openScreenWindow), keyEquivalent: "n").target = self
        viewMenu.addItem(withTitle: "Open Screen in New Tab",
                         action: #selector(openScreenTab), keyEquivalent: "t").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Pin Window on Top",
                         action: #selector(togglePin), keyEquivalent: "p").target = self
        viewMenu.addItem(.separator())
        let twinOpen = viewMenu.addItem(withTitle: "View Screen in 3D",
                                        action: #selector(openTwinFromMenu), keyEquivalent: "3")
        twinOpen.target = self
        twinOpen.isHidden = !AppBuild.twinEnabled
        twinOpenItem = twinOpen
        let twinToggle = viewMenu.addItem(withTitle: "3D Device Twin (Experimental)",
                                          action: #selector(toggleTwinGate), keyEquivalent: "")
        twinToggle.target = self
        twinToggle.state = AppBuild.twinEnabled ? .on : .off
        twinGateItem = twinToggle
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        present(message: "rPlayHub Android \(AppBuild.version)",
                detail: "Mirror and control an Android device through Google's screen-sharing "
                      + "agent, over adb. No Android Studio in the runtime path.")
    }

    @objc private func mirrorSelected() {
        guard let device = sidebar.selected else { return }
        startSession(for: device)
    }

    @objc private func stopMirroring() {
        session?.stop()
        session = nil
        healthTimer?.invalidate()
        mirror.reset()
        strip.setSessionActive(false)
        window.subtitle = ""
    }

    @objc private func refreshFromMenu() { refreshDevices() }

    @objc private func openScreenWindow() {
        screenWindow.open(stage: stage, from: splitView, title: window.title, tabbedWith: nil)
    }

    @objc private func openScreenTab() {
        screenWindow.open(stage: stage, from: splitView, title: window.title, tabbedWith: window)
    }

    @objc private func togglePin() { perform(MirrorView.Command.pin) }
}

/// The columns are separated by the shadow each side pane casts, not by a drawn line — so the
/// divider itself should not be visible. Adopted from ~/rplay-hub, which matched this against
/// Device Hub's own window.
final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
}

// MARK: - the three-column title bar

extension AppDelegate: NSToolbarDelegate {
    private static let addDeviceItem = NSToolbarItem.Identifier("addDevice")
    private static let sortItem = NSToolbarItem.Identifier("sortDevices")
    private static let sidebarItem = NSToolbarItem.Identifier("toggleSidebar")
    private static let deviceTitleItem = NSToolbarItem.Identifier("deviceTitle")
    private static let inspectorTabsItem = NSToolbarItem.Identifier("inspectorTabs")
    /// These two follow the split view's dividers, which is what cuts the bar into columns.
    private static let sidebarSeparator = NSToolbarItem.Identifier("sidebarSeparator")
    private static let inspectorSeparator = NSToolbarItem.Identifier("inspectorSeparator")

    private static let order: [NSToolbarItem.Identifier] = [
        addDeviceItem, sortItem, sidebarItem,
        sidebarSeparator,
        deviceTitleItem, .flexibleSpace,
        inspectorSeparator,
        // Pushes the icon tabs to the trailing edge of the inspector's own section; without it
        // they sit hard against the separator.
        .flexibleSpace, inspectorTabsItem,
    ]

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.order
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.order
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func icon(_ symbol: String, _ label: String, _ tip: String,
                  _ action: Selector?) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            item.target = self
            item.action = action
            return item
        }
        switch id {
        case Self.sidebarSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView,
                                                  dividerIndex: 0)
        case Self.inspectorSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView,
                                                  dividerIndex: 1)

        case Self.addDeviceItem:
            return icon("plus", "Add", "Connect a device over the network",
                        #selector(addDeviceTapped))
        case Self.sortItem:
            return icon("line.3.horizontal.decrease", "Sort", "Sort Devices",
                        #selector(sortDevicesTapped))
        case Self.sidebarItem:
            return icon("sidebar.left", "Sidebar", "Hide Sidebar", #selector(toggleSidebar))

        case Self.deviceTitleItem:
            // Two lines, as Device Hub's is: the name over the OS version. Not the standard
            // window title, which is centred across the whole bar rather than sitting where the
            // canvas begins.
            deviceTitleName.font = .systemFont(ofSize: 12, weight: .medium)
            deviceTitleDetail.font = .systemFont(ofSize: 10)
            deviceTitleDetail.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [deviceTitleName, deviceTitleDetail])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = stack
            item.label = "Device"
            return item

        case Self.inspectorTabsItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = inspector.iconTabs
            item.label = "Inspector"
            return item

        default:
            return nil
        }
    }
}

// MARK: - the sidebar's toolbar actions

extension AppDelegate {
    /// Connect a device over the network. This is what `+` means on Android: there is no pairing
    /// dance to run for an already-authorised device, just `adb connect host:port`.
    ///
    /// Port 5555 is filled in because that is what `adb tcpip 5555` opens and what practically
    /// every network device listens on; typing a bare address should just work.
    @objc func addDeviceTapped() {
        let alert = NSAlert()
        alert.messageText = "Connect to a device"
        alert.informativeText = "The device must already have wireless debugging enabled, and "
            + "have accepted this computer. Run `adb tcpip 5555` over USB first if it has not."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Restart ADB")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "192.168.1.50:5555"
        field.stringValue = UserDefaults.standard.string(forKey: "LastConnectAddress") ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let choice = alert.runModal()
        if choice == .alertSecondButtonReturn { restartAdbServer(); return }
        guard choice == .alertFirstButtonReturn else { return }
        var address = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if !address.contains(":") { address += ":5555" }      // the port is the boring part
        UserDefaults.standard.set(address, forKey: "LastConnectAddress")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let reply = try Adb.connect(address)
                AppBuild.log("connect \(address): \(reply)")
                DispatchQueue.main.async { self?.refreshDevices() }
            } catch {
                AppBuild.log("connect \(address) failed: \(error)")
                DispatchQueue.main.async {
                    self?.present(message: "Could not connect to \(address)", detail: "\(error)")
                }
            }
        }
    }

    /// Kill and restart the adb server, then reload the list. The usual cure for a device stuck
    /// in `offline`, or an `unauthorized` that persists after accepting the prompt.
    ///
    /// Any live session dies with the server, so it is torn down first rather than left to fail
    /// on its own.
    func restartAdbServer() {
        stopMirroring()
        sidebar.update(devices: [], note: "restarting the adb server…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var problem: String?
            do {
                try Adb.killServer()
                // The server needs a moment to release :5037 before it can be rebound.
                Thread.sleep(forTimeInterval: 0.6)
                try Adb.startServer()
                // And another for it to enumerate what is attached, or the first poll is empty.
                Thread.sleep(forTimeInterval: 1.0)
                AppBuild.log("adb server restarted")
                // A network device is not remembered across a restart — the new server knows
                // only about USB. Put the last one back rather than making the user retype it.
                if let last = UserDefaults.standard.string(forKey: "LastConnectAddress"),
                   !last.isEmpty {
                    if let reply = try? Adb.connect(last) {
                        AppBuild.log("reconnected \(last): \(reply)")
                    }
                }
            } catch {
                problem = "\(error)"
                AppBuild.log("adb restart failed: \(error)")
            }
            DispatchQueue.main.async {
                self?.refreshDevices()
                if let problem {
                    self?.present(message: "Could not restart the adb server", detail: problem)
                }
            }
        }
    }

    @objc func sortDevicesTapped(_ sender: Any?) {
        let menu = NSMenu()
        for option in DeviceSidebar.Sort.allCases {
            let item = menu.addItem(withTitle: option.rawValue, action: #selector(sortChosen(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = sidebar.sort == option ? .on : .off
        }
        // Anchored under the toolbar button rather than at the pointer, which is where a menu
        // hung off a toolbar item belongs.
        if let item = sender as? NSToolbarItem, let button = item.view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func sortChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = DeviceSidebar.Sort(rawValue: raw) else { return }
        sidebar.sort = option
    }

    @objc func toggleSidebar() {
        sidebar.isHidden.toggle()
    }
}
