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
    private let logPanel = LogcatPanel()
    private let screenWindow = ScreenWindow()
    private var tabBar: IconTabBar!
    private var stage: NSView!

    private var session: AgentSession?
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var inspectorTab = 0
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
                          styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                      .fullSizeContentView],
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
            mirror.topAnchor.constraint(equalTo: middle.topAnchor),
            mirror.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            mirror.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            strip.topAnchor.constraint(equalTo: mirror.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
        ])
        stage = middle

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(middle)
        splitView.addArrangedSubview(inspector)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        window.contentView = splitView
        splitView.setPosition(240, ofDividerAt: 0)
        splitView.setPosition(800, ofDividerAt: 1)

        tabBar = IconTabBar(icons: [("info.circle", "Info"), ("doc.plaintext", "Log")])
        tabBar.selected = 0
        tabBar.onSelect = { [weak self] index in self?.selectInspectorTab(index) }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = tabBar
        accessory.layoutAttribute = .right
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
            guard let device = self.sidebar.selected else {
                self.present(message: "No device selected",
                             detail: "Pick a device in the sidebar first.")
                return
            }
            self.startSession(for: device)
        }
        strip.onAction = { [weak self] action in self?.perform(action) }
    }

    private func selectInspectorTab(_ index: Int) {
        // Re-selecting the active tab collapses the pane, as Device Hub does.
        if index == inspectorTab, !inspector.isHidden || !logPanel.isHidden {
            inspector.isHidden = true
            logPanel.isHidden = true
            tabBar.selected = nil
            return
        }
        inspectorTab = index
        tabBar.selected = index
        let wanted: NSView = index == 0 ? inspector : logPanel
        if splitView.arrangedSubviews.count > 2 {
            let current = splitView.arrangedSubviews[2]
            if current !== wanted {
                splitView.removeArrangedSubview(current)
                current.removeFromSuperview()
                splitView.addArrangedSubview(wanted)
                splitView.setPosition(splitView.frame.width - 260, ofDividerAt: 1)
            }
        }
        wanted.isHidden = false
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
                self?.sidebar.update(devices: captured.0, note: captured.1)
            }
        }
    }

    private func selectionChanged(_ device: AdbDevice?) {
        guard let device else {
            inspector.setProperties("No device selected")
            mirror.deviceName = nil
            mirror.deviceSubtitle = nil
            return
        }
        window.title = "rPlayHub — \(device.displayName)"
        mirror.deviceName = device.displayName
        mirror.deviceSubtitle = device.isReady ? device.serial : device.state
        guard device.isReady else {
            inspector.setProperties(
                "\(device.displayName)\n\(device.serial)\nstate: \(device.state)")
            return
        }
        guard propertiesForSerial != device.serial else { return }
        propertiesForSerial = device.serial
        loadProperties(device)
    }

    /// getprop once per selection, off the main queue — each of these is a round trip.
    private func loadProperties(_ device: AdbDevice) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wanted = [
                ("Model", "ro.product.model"),
                ("Device", "ro.product.device"),
                ("Android", "ro.build.version.release"),
                ("SDK", "ro.build.version.sdk"),
                ("ABI", "ro.product.cpu.abi"),
                ("Build", "ro.build.display.id"),
            ]
            var lines = ["Serial   \(device.serial)"]
            for (label, key) in wanted {
                let value = (try? Adb.getprop(device.serial, key)) ?? "?"
                lines.append("\(label.padding(toLength: 9, withPad: " ", startingAt: 0))\(value)")
            }
            let text = lines.joined(separator: "\n")
            let release = (try? Adb.getprop(device.serial, "ro.build.version.release")) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard self?.propertiesForSerial == device.serial else { return }
                self?.inspector.setProperties(text)
                if !release.isEmpty { self?.mirror.deviceSubtitle = "Android \(release)" }
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
        logPanel.clear()
        strip.setSessionActive(false)

        let s = AgentSession(serial: device.serial)
        session = s
        s.onState = { [weak self] state in self?.sessionStateChanged(state) }
        s.onAgentLog = { [weak self] line in self?.logPanel.append(line) }
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
            logPanel.append("· \(step)")
        case .running:
            window.subtitle = "mirroring"
            strip.setSessionActive(true)
            attachStream()
            startHealthTimer()
        case .failed(let reason):
            window.subtitle = "failed"
            strip.setSessionActive(false)
            logPanel.append("! \(reason)")
            mirror.reset()
            present(message: "Mirroring failed", detail: reason)
        }
    }

    private func attachStream() {
        guard let session, let video = session.video else { return }
        mirror.control = session.control
        video.onFormat = { [weak self] size in self?.mirror.videoSize = size }
        video.onGeometry = { [weak self] header in
            self?.mirror.apply(header: header)
        }
        video.onDisconnect = { [weak self] reason in
            self?.logPanel.append("! video: \(reason)")
            self?.strip.setSessionActive(false)
        }
    }

    private func startHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateHealth()
        }
    }

    private func updateHealth() {
        guard let video = session?.video else { inspector.setHealth(""); return }
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
        inspector.setHealth(lines.joined(separator: "\n"))
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
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let remote = "/data/local/tmp/rplayhub-screenshot.png"
                    _ = try Adb.shell(serial, "screencap -p \(remote)")
                    let data = try Adb.shell(serial, "cat \(remote)")
                    _ = try? Adb.shell(serial, "rm -f \(remote)")
                    // `cat` through exec: is a byte-transparent channel, so this is the file.
                    try Data(data.utf8).write(to: url)
                    DispatchQueue.main.async { [weak self] in
                        self?.logPanel.append("· screenshot saved to \(url.path)")
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.logPanel.append("! screenshot: \(error)")
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
        deviceMenu.addItem(withTitle: "Refresh Devices", action: #selector(refreshFromMenu),
                           keyEquivalent: "r").target = self
        deviceItem.submenu = deviceMenu
        main.addItem(deviceItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Open Screen in New Window",
                         action: #selector(openScreenWindow), keyEquivalent: "n").target = self
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
        screenWindow.open(stage: stage, from: splitView,
                          title: window.title, tabbedWith: window)
    }
}
