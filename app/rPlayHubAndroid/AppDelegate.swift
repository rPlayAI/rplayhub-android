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
        for (pane, width) in [(sidebar as NSView, 250.0), (middle as NSView, 389.0),
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

        // Device Hub keeps these in the title bar at the trailing edge, not in the pane.
        // The accessory needs a concrete frame at the time it is added: given only Auto Layout
        // constraints it comes up zero-sized and nothing appears in the title bar at all.
        let accessory = NSTitlebarAccessoryViewController()
        inspector.iconTabs.frame = NSRect(x: 0, y: 0, width: 108, height: 28)
        accessory.view = inspector.iconTabs
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

        wireUp()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            return
        }
        window.title = "rPlayHub — \(device.displayName)"
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
        session?.stop()
        mirror.reset()
        strip.setSessionActive(false)

        let s = AgentSession(serial: device.serial)
        session = s
        s.onState = { [weak self] state in self?.sessionStateChanged(state) }
        s.onAgentLog = { line in AppBuild.log("agent: \(line)") }
        s.decoder.onFrame = { [weak self] picture in
            self?.mirror.displayLayer.present(picture)
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
            attachStream()
            startHealthTimer()
        case .failed(let reason):
            window.subtitle = "failed"
            strip.setSessionActive(false)
            mirror.reset()
            present(message: "Mirroring failed", detail: reason)
        }
    }

    private func attachStream() {
        guard let session, let video = session.video else { return }
        mirror.control = session.control
        loadDisplayShape(session.serial)
        video.onFormat = { [weak self] size in self?.mirror.videoSize = size }
        video.onGeometry = { [weak self] header in
            self?.mirror.apply(header: header)
        }
        video.onDisconnect = { [weak self] reason in
            AppBuild.log("video: \(reason)")
            self?.strip.setSessionActive(false)
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
        if video.awaitingKeyframe {
            lines.append("waiting for a keyframe (\(video.framesBeforeKeyframe) dropped)")
        }
        if let error = video.lastError { lines.append("error     \(error)") }
        inspector.info.setHealth(lines.joined(separator: "\n"))
    }

    // MARK: - the screen's right-click menu

    private var isPinned = false

    private func perform(_ command: MirrorView.Command) {
        switch command {
        case .screenshot: saveScreenshot()
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
        case .screenshot:
            saveScreenshot()
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
