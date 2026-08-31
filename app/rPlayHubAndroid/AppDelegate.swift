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
    private var twinDemo = false
    private var twinGateItem: NSMenuItem?
    private var twinOpenItem: NSMenuItem?
    private var twinDemoItem: NSMenuItem?
    private var twinBackImageItem: NSMenuItem?
    private var twinFacingMeItem: NSMenuItem?
    private var screenOffItem: NSMenuItem?

    /// Clipboard sync, scrcpy-style: device changes land on the Mac clipboard automatically,
    /// Mac changes are pushed to the device on a one-second poll (AppKit offers no pasteboard
    /// notification; polling changeCount is what everyone does). On by default.
    private var clipboardTimer: Timer?
    private var lastClipboardText: String?
    private var lastPasteboardCount = NSPasteboard.general.changeCount
    private var clipboardSyncItem: NSMenuItem?
    private var clipboardSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: "SyncClipboard") == nil
            ? true : UserDefaults.standard.bool(forKey: "SyncClipboard")
    }

    /// Device audio on the Mac's speakers, scrcpy's headline feature. On by default; the toggle
    /// works live because the agent starts and stops capture by control message.
    private var audioItem: NSMenuItem?
    private var audioForwardingEnabled: Bool {
        UserDefaults.standard.object(forKey: "ForwardAudio") == nil
            ? true : UserDefaults.standard.bool(forKey: "ForwardAudio")
    }

    /// scrcpy's pause (frozen frame, no bandwidth) and its --display-id, as menu items. Both
    /// ride the same start/stopVideoStream messages; which display is current also routes every
    /// touch, since MotionEvents carry a display id.
    private var pauseItem: NSMenuItem?
    private var displaysMenu: NSMenu?
    private var createdDisplayIds: Set<Int32> = []
    private var closeDisplayItem: NSMenuItem?
    private var mirrorToggleItem: NSMenuItem?
    /// Whether the picture is actually shown. A prepared session (agent pushed + started on device
    /// select) runs with this false, hidden behind the View Screen gate, until the user reveals it.
    private var mirrorRevealed = false
    private var displayPaused = false
    private var currentDisplayId: Int32 = 0

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
        // Kept as properties so a fusion window can collapse them: the picture there should run
        // to the window's edge, with no stage padding and no reserved strip height.
        stageTopPad = mirror.topAnchor.constraint(equalTo: middle.topAnchor, constant: 16)
        stageLeadPad = mirror.leadingAnchor.constraint(equalTo: middle.leadingAnchor, constant: 12)
        stageTrailPad = mirror.trailingAnchor.constraint(equalTo: middle.trailingAnchor, constant: -12)
        stripMinHeight = strip.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        // A hidden strip still reports its intrinsic height; only a required zero-height cap
        // actually removes the band it reserves. Activated by fusion, deactivated on close.
        stripZeroHeight = strip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stageTopPad!, stageLeadPad!, stageTrailPad!,
            strip.topAnchor.constraint(equalTo: mirror.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            stripMinHeight!,
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
        for (pane, width) in [(sidebar as NSView, 210.0), (middle as NSView, 520.0),
                              (inspector as NSView, 320.0)] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            let resting = pane.widthAnchor.constraint(equalToConstant: width)
            // The stage's resting width is only a starting preference: resizing the window should
            // pour all the new space into the picture, so its constraint must lose to everything.
            resting.priority = NSLayoutConstraint.Priority(pane === middle ? 250 : 700)
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
        window.setContentSize(NSSize(width: 1090, height: 760))

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
        sidebar.onStopMirror = { [weak self] in self?.stopMirroring() }
        sidebar.isMirroring = { [weak self] in self?.mirrorRevealed ?? false }
        sidebar.onDesktopMode = { [weak self] device in self?.requestDesktopMode(on: device) }
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
            self.revealMirror(for: device)
        }
        strip.onAction = { [weak self] action in self?.perform(action) }
        mirror.onCommand = { [weak self] command in self?.perform(command) }
        mirror.onFilesDropped = { [weak self] urls in self?.handleDroppedFiles(urls) }
        inspector.apps.onFusion = { [weak self] package in self?.startFusion(package: package) }
        // A fusion window hides the control strip (it drives the phone, not the app window);
        // whatever closed the window, the strip belongs back in the main stage. And closing the
        // window is closing the feature: tear the virtual display down too, or it keeps streaming
        // invisibly (and each Fusion click would leak another display on the device).
        screenWindow.onClose = { [weak self] in
            guard let self else { return }
            self.strip.isHidden = false
            self.mirror.borderless = false   // the main stage gets its device bezel back
            self.stageTopPad?.constant = 16
            self.stageLeadPad?.constant = 12
            self.stageTrailPad?.constant = -12
            self.stripMinHeight?.constant = 50
            self.stripZeroHeight?.isActive = false
            if self.currentDisplayId != 0, self.createdDisplayIds.contains(self.currentDisplayId) {
                self.closeVirtualDisplay()
            }
        }
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
        // Prepare on select: push and start the agent so the stream is live and buffering, but keep
        // it behind the View Screen gate. The user still clicks View Screen (or Start Screen
        // Mirroring) to reveal it — which is then instant, with the app_process cold start already paid.
        startSession(for: device, reveal: false)
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

    /// `reveal: false` prepares the session — pushes and starts the agent so the stream is live —
    /// but leaves the picture behind the View Screen gate until the user reveals it.
    private func startSession(for device: AdbDevice, reveal: Bool = true) {
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
        mirror.autoReveal = reveal          // reset() set it true; a prepared session stays gated
        strip.setSessionActive(false)
        sessionReachedRunning = false

        let s = AgentSession(serial: device.serial)
        session = s
        mirrorRevealed = reveal
        refreshMirrorToggle()
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
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        case .deploying(let step):
            window.subtitle = step
        case .running:
            // A prepared (unrevealed) session is live but hidden — don't announce it as mirroring
            // or light the control strip until the user reveals it.
            window.subtitle = mirrorRevealed ? "mirroring" : "ready"
            strip.setSessionActive(mirrorRevealed)
            sessionReachedRunning = true
            attachStream()
            startHealthTimer()
            // Fusion or Desktop Mode queued before the session was up: request the display now.
            if pendingFusionPackage != nil || desktopModeRequested, !fusionRequested,
               let control = session?.control {
                fusionRequested = true
                control.send(ControlMessage.stopVideoStream(displayId: currentDisplayId))
                control.send(ControlMessage.createNewDisplay(width: 1920, height: 1080, dpi: 240,
                                                             decorations: desktopModeRequested))
                AppBuild.log("fusion: requested a display for \(pendingFusionPackage ?? "desktop mode")")
            }
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
            self?.adoptDisplay(header.displayId)
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
        startClipboardSyncIfEnabled()
        if audioForwardingEnabled { session.setAudioForwarding(true) }
        displayPaused = false
        pauseItem?.title = "Pause Display"
        currentDisplayId = 0
        mirror.displayId = 0
        createdDisplayIds = []           // virtual displays die with the previous agent
        closeDisplayItem?.isHidden = true
        inspector.apps.launchDisplayId = 0
        session.control?.onDisplays = { [weak self] displays in
            self?.rebuildDisplaysMenu(displays)
        }
        session.control?.send(ControlMessage.displayConfigurationRequest())
    }

    // MARK: - virtual displays (scrcpy --new-display)

    /// Fusion: create a virtual display and, once its frames arrive and the viewer adopts it,
    /// launch the chosen app onto it (adoptDisplay performs the launch — the id is only known
    /// from the packet headers). Starts a session first if none is running.
    private var pendingFusionPackage: String?
    private var fusionRequested = false
    /// Desktop Mode: fusion without an app — the 1920×1080 display's own desktop shell (wallpaper,
    /// taskbar, launcher) IS the content, in a chromeless window titled "Desktop".
    private var desktopModeRequested = false
    // The stage's padding around the picture and the strip's reserved height — collapsed to zero
    // while a fusion window is up, restored when it closes.
    private var stageTopPad: NSLayoutConstraint?
    private var stageLeadPad: NSLayoutConstraint?
    private var stageTrailPad: NSLayoutConstraint?
    private var stripMinHeight: NSLayoutConstraint?
    private var stripZeroHeight: NSLayoutConstraint?

    /// Fuse whatever app is selected in the Apps tab — the keyboard path to what the Apps-list
    /// right-click "Open on Virtual Display" does, so fusion is drivable without the mouse.
    @objc private func fuseSelectedApp() {
        guard let package = inspector.apps.selectedPackageId else {
            present(message: "No app selected",
                    detail: "Pick an app in the Apps tab, then press ⇧⌘F.")
            return
        }
        startFusion(package: package)
    }

    @objc private func startDesktopMode() { requestDesktopMode(on: nil) }

    /// `device` targets a specific phone (the sidebar row's context menu); nil means the current
    /// session or the selected device — Desktop Mode is per-device, like everything else here.
    private func requestDesktopMode(on device: AdbDevice?) {
        desktopModeRequested = true
        if let device, session?.serial != device.serial {
            startSession(for: device, reveal: true)   // the .running hook fires the request
            return
        }
        if let control = session?.control {
            control.send(ControlMessage.stopVideoStream(displayId: currentDisplayId))
            control.send(ControlMessage.createNewDisplay(width: 1920, height: 1080, dpi: 240,
                                                         decorations: true))
            AppBuild.log("fusion: requested a desktop-mode display")
        } else if let device = sidebar.selected ?? sidebar.devices.first(where: { $0.isReady }) {
            startSession(for: device, reveal: true)   // the .running hook fires the request
        } else {
            desktopModeRequested = false
            present(message: "No device", detail: "Connect a device first, then try Desktop Mode again.")
        }
    }

    /// "com.google.android.youtube" → "Youtube": the last segment stands in for the real label
    /// until fetchAppLabel replaces it with the launcher's own name.
    private func fusionTitle(for package: String) -> String {
        guard let segment = package.split(separator: ".").last else { return package }
        return segment.prefix(1).uppercased() + segment.dropFirst()
    }

    /// The real app name, the one the launcher shows. Labels live in APK resources nothing in the
    /// adb shell can resolve, so a tiny entry in the agent jar (AppLabel, run via app_process —
    /// already on the device) resolves it the way the launcher does; the window is retitled when
    /// the answer arrives, a beat after the placeholder.
    private func fetchAppLabel(package: String) {
        guard let serial = session?.serial else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let cmd = "CLASSPATH=\(AgentSession.devicePathBase)/\(AgentSession.jarName)"
                + " app_process / com.android.tools.screensharing.AppLabel \(package) 2>/dev/null"
            guard let out = try? Adb.shell(serial, cmd) else { return }
            // AppLabel prints "label<TAB>base64png"; take the label field only, or the icon blob
            // ends up in the title. The last non-empty line is the answer (any warnings precede it).
            let line = out.split(separator: "\n").last(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }) ?? ""
            let label = line.components(separatedBy: "\t").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !label.isEmpty, label != package else { return }
            DispatchQueue.main.async { self?.screenWindow.window?.title = label }
        }
    }

    /// The fusion window treatment: chromeless (no control strip — it drives the phone), named
    /// for what it shows, and sized snugly around the 16:9 picture rather than inheriting the
    /// stage's tall frame with fat empty margins. Resizes keep the aspect, so it stays snug.
    private func dressFusionWindow(title: String) {
        if !screenWindow.isOpen { openScreenWindow() }
        strip.isHidden = true
        mirror.borderless = true            // raw picture, no device bezel
        stageTopPad?.constant = 0           // and no stage padding or strip space around it
        stageLeadPad?.constant = 0
        stageTrailPad?.constant = 0
        stripMinHeight?.constant = 0
        stripZeroHeight?.isActive = true
        // The fusion display mirrors the phone's keyguard when the phone sits locked — a clock
        // over wallpaper you cannot enter. The phone has adb access, so dismiss it.
        if let serial = session?.serial {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? Adb.shell(serial, "wm dismiss-keyguard")
            }
        }
        guard let w = screenWindow.window else { return }
        w.title = title
        // A classic title bar — traffic lights and the app's name — with the picture flush
        // against it below; only the content area keeps the 16:9 aspect.
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.setContentSize(NSSize(width: 1152, height: 648))
    }

    private func startFusion(package: String) {
        // Already showing a fusion display: reuse it. Launching onto the existing display is
        // instant, while a second create-while-streaming can bounce the agent (it recovers via
        // the queued request, but that costs ~15 seconds and leaks the first display).
        if currentDisplayId != 0, createdDisplayIds.contains(currentDisplayId),
           let serial = session?.serial {
            let id = currentDisplayId
            AppBuild.log("fusion: reusing display \(id) for \(package)")
            DispatchQueue.global(qos: .userInitiated).async {
                try? Adb.launch(serial, package: package, displayId: id)
            }
            dressFusionWindow(title: fusionTitle(for: package))
            fetchAppLabel(package: package)
            return
        }
        pendingFusionPackage = package
        if let control = session?.control {
            control.send(ControlMessage.stopVideoStream(displayId: currentDisplayId))
            control.send(ControlMessage.createNewDisplay(width: 1920, height: 1080, dpi: 240,
                                                         decorations: false))
            AppBuild.log("fusion: requested a display for \(package)")
        } else if let device = sidebar.selected ?? sidebar.devices.first(where: { $0.isReady }) {
            startSession(for: device, reveal: true)   // the .running hook fires the request
        } else {
            pendingFusionPackage = nil
            present(message: "No device", detail: "Connect a device first, then try Fusion again.")
        }
    }

    @objc private func createVirtualDisplay(_ sender: NSMenuItem) {
        guard let dims = sender.representedObject as? [NSNumber], dims.count == 3,
              let session, let control = session.control else { return }
        // Stop the current stream; the agent starts streaming the new display on its own, and
        // adoptDisplay() follows the id change when its packets arrive.
        control.send(ControlMessage.stopVideoStream(displayId: currentDisplayId))
        control.send(ControlMessage.createNewDisplay(width: dims[0].int32Value,
                                                     height: dims[1].int32Value,
                                                     dpi: dims[2].int32Value,
                                                     decorations: true))
        AppBuild.log("requested a \(dims[0])×\(dims[1]) virtual display")
    }

    @objc private func closeVirtualDisplay() {
        guard let session, let control = session.control,
              createdDisplayIds.contains(currentDisplayId) else { return }
        control.send(ControlMessage.destroyNewDisplay(displayId: currentDisplayId))
        createdDisplayIds.remove(currentDisplayId)
        adoptDisplay(0)
        control.send(ControlMessage.startVideoStream(displayId: 0,
                                                     width: Int32(maxVideoSize.width),
                                                     height: Int32(maxVideoSize.height)))
    }

    /// The stream told us which display it carries. Called from onGeometry when the id in the
    /// packet headers differs from the one we thought we were showing — which is how a freshly
    /// created virtual display announces itself.
    private func adoptDisplay(_ id: Int32) {
        guard id != currentDisplayId else { return }
        let known = displaysMenu?.items.contains {
            ($0.representedObject as? NSNumber)?.int32Value == id } ?? false
        if id != 0 && !known { createdDisplayIds.insert(id) }
        currentDisplayId = id
        mirror.displayId = id
        inspector.apps.launchDisplayId = id
        closeDisplayItem?.isHidden = !createdDisplayIds.contains(id)
        displaysMenu?.items.forEach {
            $0.state = ($0.representedObject as? NSNumber)?.int32Value == id ? .on : .off
        }
        if let session {
            if id == 0 { loadDisplayShape(session.serial) } else { mirror.displayShape = nil }
            session.control?.send(ControlMessage.displayConfigurationRequest())
        }
        AppBuild.log("now showing display \(id)")
        // Fusion: the virtual display's frames arrived and the viewer adopted it — put the chosen
        // app on it and pop the stage into its own resizable window: chromeless (no control
        // strip — that strip drives the PHONE, and this window is the app), titled with the app.
        if id != 0, let package = pendingFusionPackage, let serial = session?.serial {
            pendingFusionPackage = nil
            fusionRequested = false
            AppBuild.log("fusion: launching \(package) on display \(id)")
            DispatchQueue.global(qos: .userInitiated).async {
                try? Adb.launch(serial, package: package, displayId: id)
            }
            dressFusionWindow(title: fusionTitle(for: package))
            fetchAppLabel(package: package)
        } else if id != 0, desktopModeRequested {
            // Desktop Mode: nothing to launch — the display's own desktop shell is the content.
            desktopModeRequested = false
            fusionRequested = false
            dressFusionWindow(title: "Desktop")
        }
    }

    // MARK: - pause, and picking a display

    @objc private func togglePauseDisplay() {
        guard let session, let control = session.control, sessionReachedRunning else { return }
        displayPaused.toggle()
        if displayPaused {
            control.send(ControlMessage.stopVideoStream(displayId: currentDisplayId))
            window.subtitle = "paused"
        } else {
            control.send(ControlMessage.startVideoStream(displayId: currentDisplayId,
                                                         width: Int32(maxVideoSize.width),
                                                         height: Int32(maxVideoSize.height)))
            window.subtitle = "mirroring"
        }
        pauseItem?.title = displayPaused ? "Resume Display" : "Pause Display"
        AppBuild.log(displayPaused ? "display paused" : "display resumed")
    }

    private func rebuildDisplaysMenu(_ displays: [ControlSender.DisplayDescriptor]) {
        guard let menu = displaysMenu else { return }
        menu.removeAllItems()
        for display in displays {
            let name = display.id == 0 ? "Built-in Display" : "Display \(display.id)"
            let item = menu.addItem(withTitle: "\(name)  \(display.width)×\(display.height)",
                                    action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: display.id)
            item.state = display.id == currentDisplayId ? .on : .off
        }
        AppBuild.log("device reports \(displays.count) display(s)")
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int32Value,
              let session, let control = session.control, id != currentDisplayId else { return }
        control.send(ControlMessage.stopVideoStream(displayId: currentDisplayId))
        displayPaused = false
        pauseItem?.title = "Pause Display"
        adoptDisplay(id)
        control.send(ControlMessage.startVideoStream(displayId: id,
                                                     width: Int32(maxVideoSize.width),
                                                     height: Int32(maxVideoSize.height)))
    }

    @objc private func toggleAudio() {
        let enabled = !audioForwardingEnabled
        UserDefaults.standard.set(enabled, forKey: "ForwardAudio")
        audioItem?.state = enabled ? .on : .off
        session?.setAudioForwarding(enabled)
        AppBuild.log("audio forwarding \(enabled ? "on" : "off")")
    }

    // MARK: - clipboard sync

    @objc private func toggleClipboardSync() {
        let enabled = !clipboardSyncEnabled
        UserDefaults.standard.set(enabled, forKey: "SyncClipboard")
        clipboardSyncItem?.state = enabled ? .on : .off
        if enabled {
            startClipboardSyncIfEnabled()
        } else {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
            session?.control?.send(ControlMessage.stopClipboardSync())
        }
        AppBuild.log("clipboard sync \(enabled ? "on" : "off")")
    }

    private func startClipboardSyncIfEnabled() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        guard clipboardSyncEnabled, let control = session?.control else { return }
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string) ?? ""
        lastClipboardText = text
        lastPasteboardCount = pasteboard.changeCount
        control.send(ControlMessage.startClipboardSync(text: text))
        control.onClipboardChanged = { [weak self] text in
            guard let self, !text.isEmpty, text != self.lastClipboardText else { return }
            self.lastClipboardText = text
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastPasteboardCount = pb.changeCount
            AppBuild.log("clipboard: \(text.count) chars from the device")
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
    }

    private func pollPasteboard() {
        guard let control = session?.control else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text != lastClipboardText else { return }
        lastClipboardText = text
        control.send(ControlMessage.startClipboardSync(text: text))
        AppBuild.log("clipboard: \(text.count) chars to the device")
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
        if let audio = session?.audio {
            lines.append("audio     \(audio.packetsReceived) pkts"
                         + (audio.packetsDropped > 0 ? " (\(audio.packetsDropped) dropped)" : ""))
            if let error = audio.lastError { lines.append("audio err \(error)") }
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

    /// Menu twin to the "Set Facing Me" button in the 3D view: capture the phone's current pose
    /// as face-on. Only meaningful while the 3D view is up.
    @objc private func setTwinFacingMe() {
        guard twinActive else {
            present(message: "Open the 3D view first",
                    detail: "Choose View ▸ View Screen in 3D, then Set Facing Me.")
            return
        }
        twin?.recenter()
    }

    /// Pick an image to wear on the 3D twin's back — a real device back, for any brand. Clearing
    /// the selection (Cancel with the field emptied, or choosing again) restores the Pixel look.
    @objc private func chooseTwinBackImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Back"
        panel.message = "Choose a device back image for the 3D twin (Cancel to reset to Pixel)."
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: TwinView.backImageKey)
            AppBuild.log("twin: back image set to \(url.lastPathComponent)")
        } else {
            UserDefaults.standard.removeObject(forKey: TwinView.backImageKey)
            AppBuild.log("twin: back image reset to the default")
        }
        // Rebuild the scene if the twin is showing, so the change is immediate.
        if twinActive, let session, let video = session.video {
            twin?.activate(displaySize: video.lastHeader?.displaySize ?? CGSize(width: 1080, height: 2400))
        }
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
        twinDemoItem?.isHidden = !enabled
        twinFacingMeItem?.isHidden = !enabled
        twinBackImageItem?.isHidden = !enabled
        mirror.setTwinVisible(enabled)
        if !enabled, twinActive { exitTwin() }
        AppBuild.log("3D device twin \(enabled ? "enabled" : "disabled")")
        if enabled, session != nil, session?.sensor == nil {
            window.subtitle = "reconnect to feed the 3D twin orientation"
        }
    }

    /// One-click demo: enter 3D, drive the orientation through all poses on a loop, and walk the
    /// device through some nice live content (a website, then a video) so the rotating twin shows
    /// a real screen. For recording a demo reel.
    @objc private func showTwinDemo() {
        guard AppBuild.twinEnabled else { return }
        guard let serial = session?.serial else {
            present(message: "No live session", detail: "Start mirroring first, then Show 3D Demo.")
            return
        }
        if !twinActive { toggleTwin(demo: true) } else { twinDemo = true; startTwinDemoGyro() }
        // Walk the device through content while the twin turns: a website, then a video that we
        // rotate to landscape so it fills the screen — which also shows the twin handling a
        // landscape panel. Best-effort; failures are cosmetic. Auto-rotate is restored on exit.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? Adb.shell(serial, "am start -a android.intent.action.VIEW -d "
                               + Adb.shellQuote("https://www.google.com/search?q=pixel+9a"))
            Thread.sleep(forTimeInterval: 10)
            _ = try? Adb.shell(serial, "am start -a android.intent.action.VIEW -d "
                               + Adb.shellQuote("https://www.youtube.com/watch?v=aqz-KE-bpKQ"))
            Thread.sleep(forTimeInterval: 9)
            // Force landscape: YouTube goes fullscreen, and the twin's panel counter-rotates.
            _ = try? Adb.shell(serial, "settings put system accelerometer_rotation 0")
            _ = try? Adb.shell(serial, "settings put system user_rotation 1")
        }
        AppBuild.log("twin: demo started")
    }

    private func startTwinDemoGyro() {
        let start = Date()
        twin?.orientationSource = { Self.fakeGyro(Float(Date().timeIntervalSince(start)), sweep: "all") }
        // The demo needs a reference to show deltas against; the choreography holds its base pose
        // for the first seconds, so calibrating now anchors face-on to it.
        twin?.recenter()
    }

    /// Not a second viewer — a display mode. The 3D view takes the mirror's place in the middle
    /// pane; exiting puts the flat view back. One stream, one picture on screen.
    private func toggleTwin(demo: Bool = false) {
        if twinActive { exitTwin(); return }
        twinDemo = demo
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
            // Tapping the 3D screen injects a touch through the flat viewer's same send path.
            created.onMotion = { [weak self] point, action in
                self?.mirror.injectMotion(point, action: action)
            }
            twin = created
            return created
        }()
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

        // Choose the orientation source AFTER activate(), which resets the reference — otherwise
        // the demo's own reference (its base pose) would be overwritten and the choreography would
        // play against the wrong baseline, leaving the twin stuck at an offset angle.
        let fake = ProcessInfo.processInfo.environment["RPLAYHUB_FAKE_GYRO"]
        if twinDemo {
            twin = tv
            startTwinDemoGyro()
        } else if fake == "1" || fake?.hasPrefix("sweep:") == true {
            let start = Date()
            let axis = fake?.hasPrefix("sweep:") == true ? String(fake!.dropFirst(6)) : ""
            tv.orientationSource = { Self.fakeGyro(Float(Date().timeIntervalSince(start)), sweep: axis) }
            // Anchor the reference to the fake gyro's base pose (its t≈0 output), so the body-frame
            // delta cancels the base out and a sweep about one axis stays on that axis.
            tv.recenter()
            AppBuild.log("twin: using the fake gyro\(axis.isEmpty ? " (scripted)" : " (sweep:\(axis))")")
        } else {
            tv.orientationSource = { [weak self] in self?.session?.sensor?.latest }
        }
        twinActive = true
        mirror.setTwinActive(true)
        twinOpenItem?.title = "Exit 3D View"
        if session.sensor == nil {
            AppBuild.log("twin: no sensor channel in this session — static pose until reconnect")
        }
    }

    /// Fake gyro for verifying the orientation math without a hand on the phone. The base pose
    /// is the REAL rotation vector measured on the Pixel 9a standing vertically — so the test
    /// starts where the device actually sits, and "Set Facing Me" against it mirrors reality.
    ///
    /// Rotations are applied in the phone's OWN body frame (base · rot), matching how the twin now
    /// resolves real motion (ref⁻¹ · q). Because the demo calibrates its reference to `base`, the
    /// body delta cancels the base out cleanly, so a body axis maps straight onto a screen axis:
    /// y is the turntable (yaw), x is the nod (pitch), z is the in-plane spin (roll). A `sweep` of
    /// pitch therefore stays pure pitch — the check for the axis-coupling this replaced.
    private static func fakeGyro(_ elapsed: Float, sweep: String) -> simd_quatf {
        let base = simd_normalize(simd_quatf(ix: 0.59, iy: -0.39, iz: -0.39, r: 0.59))
        let angle = elapsed * (30 * .pi / 180)   // 30°/s
        func rot(_ a: Float, _ x: Float, _ y: Float, _ z: Float) -> simd_quatf {
            simd_quatf(angle: a, axis: simd_float3(x, y, z))
        }
        switch sweep {
        case "yaw":   return base * rot(angle, 0, 1, 0)   // body up → turntable
        case "pitch": return base * rot(angle, 1, 0, 0)   // body right → nod toward/away
        case "roll":  return base * rot(angle, 0, 0, 1)   // body forward → in-plane spin
        case "all":
            // A looping demo reel: hold face-on, turn to the back and hold there so the engraved
            // G reads on camera, finish the turn, then a pitch nod and a roll. Eased throughout.
            let period: Float = 28
            let t = elapsed.truncatingRemainder(dividingBy: period)
            func ease(_ p: Float) -> Float { p * p * (3 - 2 * p) }   // smoothstep
            func seg(_ start: Float, _ len: Float) -> Float { ease(max(0, min(1, (t - start) / len))) }
            let half = Float.pi
            if t < 3 {           return base }                                    // hold face-on
            else if t < 7 {      return base * rot(seg(3, 4) * half, 0, 1, 0) }   // turn to the back
            else if t < 10 {     return base * rot(half, 0, 1, 0) }               // HOLD on the back (G)
            else if t < 14 {     return base * rot(half + seg(10, 4) * half, 0, 1, 0) }  // finish the turn
            else if t < 19 {     return base * rot(seg(14, 5) * (50 * .pi / 180) - (25 * .pi / 180), 1, 0, 0) }  // pitch ±25°
            else if t < 24 {     return base * rot(seg(19, 5) * (60 * .pi / 180) - (30 * .pi / 180), 0, 0, 1) }  // roll ±30°
            else {               return base }                                    // settle face-on
        default:      break
        }
        switch Int(elapsed / 4) % 5 {
        case 1:   return base * rot(35 * .pi / 180, 0, 1, 0)   // yaw
        case 2:   return base * rot(25 * .pi / 180, 1, 0, 0)   // pitch
        case 3:   return base * rot(30 * .pi / 180, 0, 0, 1)   // roll
        default:  return base
        }
    }

    private func exitTwin() {
        guard twinActive, let tv = twin else { return }
        if twinDemo, let serial = session?.serial {
            // Undo the demo's forced landscape.
            DispatchQueue.global(qos: .utility).async {
                _ = try? Adb.shell(serial, "settings put system user_rotation 0")
                _ = try? Adb.shell(serial, "settings put system accelerometer_rotation 1")
            }
        }
        tv.deactivate()
        tv.isHidden = true
        mirror.isHidden = false
        twinActive = false
        twinDemo = false
        mirror.setTwinActive(false)
        twinOpenItem?.title = "View Screen in 3D"
        if let session {
            session.decoder.outputBGRA = false
            restartVideoStream()
        }
    }

    private func restartVideoStream() {
        guard let control = session?.control else { return }
        control.send(ControlMessage.stopVideoStream(displayId: currentDisplayId))
        control.send(ControlMessage.startVideoStream(displayId: currentDisplayId,
                                                     width: Int32(maxVideoSize.width),
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
        // One toggle entry — its title flips to match whether a session runs (set both in
        // validateMenuItem and directly on state change, so it is right even if the menu never
        // opened to trigger validation).
        let mirrorToggle = deviceMenu.addItem(withTitle: "Start Screen Mirroring",
                                              action: #selector(toggleMirroring), keyEquivalent: "m")
        mirrorToggle.target = self
        mirrorToggleItem = mirrorToggle
        // The Rotate button asks the agent for a FIXED quadrant; once used, the picture no longer
        // follows the phone's own sensor and hand-rotation fights the frozen orientation. This is
        // the way back (the agent's -1: follow the device again).
        deviceMenu.addItem(withTitle: "Follow Device Rotation",
                           action: #selector(followDeviceRotation), keyEquivalent: "").target = self
        deviceMenu.addItem(.separator())
        let screenOff = deviceMenu.addItem(withTitle: "Turn Screen Off While Mirroring",
                                           action: #selector(toggleScreenOff), keyEquivalent: "")
        screenOff.target = self
        screenOff.state = UserDefaults.standard.bool(forKey: "TurnScreenOffWhileMirroring")
            ? .on : .off
        screenOffItem = screenOff
        let clipSync = deviceMenu.addItem(withTitle: "Synchronize Clipboard",
                                          action: #selector(toggleClipboardSync), keyEquivalent: "")
        clipSync.target = self
        clipSync.state = clipboardSyncEnabled ? .on : .off
        clipboardSyncItem = clipSync
        let audio = deviceMenu.addItem(withTitle: "Forward Audio",
                                       action: #selector(toggleAudio), keyEquivalent: "")
        audio.target = self
        audio.state = audioForwardingEnabled ? .on : .off
        audioItem = audio
        deviceMenu.addItem(.separator())
        let pause = deviceMenu.addItem(withTitle: "Pause Display",
                                       action: #selector(togglePauseDisplay), keyEquivalent: "")
        pause.target = self
        pauseItem = pause
        let displayPicker = deviceMenu.addItem(withTitle: "Mirror Display", action: nil,
                                               keyEquivalent: "")
        let displaySub = NSMenu(title: "Mirror Display")
        displayPicker.submenu = displaySub
        displaysMenu = displaySub
        deviceMenu.addItem(withTitle: "Desktop Mode", action: #selector(startDesktopMode),
                           keyEquivalent: "d").target = self
        let fuse = deviceMenu.addItem(withTitle: "Open Selected App on Virtual Display",
                                      action: #selector(fuseSelectedApp), keyEquivalent: "f")
        fuse.keyEquivalentModifierMask = [.command, .shift]
        fuse.target = self
        let newDisplay = deviceMenu.addItem(withTitle: "New Virtual Display", action: nil,
                                            keyEquivalent: "")
        let newDisplaySub = NSMenu(title: "New Virtual Display")
        for (title, w, h, dpi) in [("Phone  1080×2340", Int32(1080), Int32(2340), Int32(420)),
                                   ("Tablet  1280×800", 1280, 800, 213),
                                   ("Desktop  1920×1080", 1920, 1080, 240)] {
            let item = newDisplaySub.addItem(withTitle: title,
                                             action: #selector(createVirtualDisplay(_:)),
                                             keyEquivalent: "")
            item.target = self
            item.representedObject = [w, h, dpi] as [NSNumber]
        }
        newDisplay.submenu = newDisplaySub
        let closeDisplay = deviceMenu.addItem(withTitle: "Close Virtual Display",
                                              action: #selector(closeVirtualDisplay),
                                              keyEquivalent: "")
        closeDisplay.target = self
        closeDisplay.isHidden = true
        closeDisplayItem = closeDisplay
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
        let facingMe = viewMenu.addItem(withTitle: "Set Facing Me",
                                        action: #selector(setTwinFacingMe), keyEquivalent: "")
        facingMe.target = self
        facingMe.isHidden = !AppBuild.twinEnabled
        twinFacingMeItem = facingMe
        let twinDemoMenu = viewMenu.addItem(withTitle: "Show 3D Demo",
                                            action: #selector(showTwinDemo), keyEquivalent: "")
        twinDemoMenu.target = self
        twinDemoMenu.isHidden = !AppBuild.twinEnabled
        twinDemoItem = twinDemoMenu
        let backImage = viewMenu.addItem(withTitle: "Set 3D Back Image…",
                                         action: #selector(chooseTwinBackImage), keyEquivalent: "")
        backImage.target = self
        backImage.isHidden = !AppBuild.twinEnabled
        twinBackImageItem = backImage
        let twinToggle = viewMenu.addItem(withTitle: "3D Device Twin (Experimental)",
                                          action: #selector(toggleTwinGate), keyEquivalent: "")
        twinToggle.target = self
        twinToggle.state = AppBuild.twinEnabled ? .on : .off
        twinGateItem = twinToggle
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let help = helpMenu.addItem(withTitle: "rPlayHub Android Help", action: #selector(openHelp),
                                    keyEquivalent: "?")   // ⌘? is the standard Help shortcut
        help.target = self
        helpMenu.addItem(.separator())
        let gh = helpMenu.addItem(withTitle: "rPlayHub Android on GitHub",
                                  action: #selector(openGitHub), keyEquivalent: "")
        gh.target = self
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu   // routes the Help-menu search field and ⌘? here

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        present(message: "rPlayHub Android \(AppBuild.version)",
                detail: "Mirror and control an Android device through Google's screen-sharing "
                      + "agent, over adb. No Android Studio in the runtime path.")
    }

    @objc private func mirrorSelected() {
        guard let device = sidebar.selected else { return }
        revealMirror(for: device)
    }

    /// Where the Help menu points: docs/help.html on main, served by GitHub Pages so it renders
    /// as a real page rather than as source.
    private static let helpURL = "https://rplayai.github.io/rplayhub-android/help.html"
    private static let repoURL = "https://github.com/rPlayAI/rplayhub-android"

    @objc private func openHelp() {
        if let url = URL(string: Self.helpURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func openGitHub() {
        if let url = URL(string: Self.repoURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func followDeviceRotation() {
        session?.control?.send(ControlMessage.setDeviceOrientation(-1))
    }

    @objc private func toggleMirroring() {
        if mirrorRevealed { stopMirroring() } else { mirrorSelected() }
    }

    /// Reveal a prepared session instantly, or start one if none is prepared for this device.
    private func revealMirror(for device: AdbDevice) {
        if let session, session.serial == device.serial {
            mirror.reveal()              // agent already running — show the buffered stream now
            mirrorRevealed = true
            strip.setSessionActive(true)
            window.subtitle = "mirroring"
            refreshMirrorToggle()
        } else {
            startSession(for: device, reveal: true)
        }
    }

    /// Keep the single Start/Stop toggle's title in step with what the user sees (revealed = Stop).
    private func refreshMirrorToggle() {
        mirrorToggleItem?.title = mirrorRevealed ? "Stop Screen Mirroring" : "Start Screen Mirroring"
    }

    /// Retitle the single Start/Stop toggle to match the live state; leave every other item alone.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMirroring) {
            item.title = mirrorRevealed ? "Stop Screen Mirroring" : "Start Screen Mirroring"
        }
        return true
    }

    @objc private func stopMirroring() {
        if twinActive { exitTwin() }
        session?.stop()
        session = nil
        mirrorRevealed = false
        healthTimer?.invalidate()
        mirror.reset()
        strip.setSessionActive(false)
        window.subtitle = ""
        refreshMirrorToggle()
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
