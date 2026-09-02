//
//  DeviceSidebar.swift
//  The device list: search, rows, status dots, context menu.
//
//  Same shape as ~/rplay-hub's, backed by `adb devices -l` instead of usbmux. The states adb
//  reports are more varied than iOS's paired/unpaired, and two of them are things the user can
//  actually fix — "unauthorized" wants the dialog accepted on the device, "offline" usually wants
//  the cable reseated — so the row says which rather than just refusing to connect.
//

import AppKit

final class DeviceSidebar: NSView {
    /// A row was chosen. nil when the selection was cleared.
    var onSelect: ((AdbDevice?) -> Void)?
    /// "Mirror" from the row's context menu or a double click.
    var onMirror: ((AdbDevice) -> Void)?
    var onStopMirror: (() -> Void)?
    /// Desktop Mode on a specific device — the clicked row's, not necessarily the selected one.
    var onDesktopMode: ((AdbDevice) -> Void)?
    /// Open the device's storage in Finder.
    var onShowInFinder: ((AdbDevice) -> Void)?
    /// Install the companion Share app on the device.
    var onInstallCompanion: ((AdbDevice) -> Void)?
    /// Shut an emulator down (the Disconnect entry, retitled for an emulator row).
    var onShutDownEmulator: ((AdbDevice) -> Void)?
    /// Whether a mirror session is currently live — drives the toggle entry's title/behaviour.
    var isMirroring: (() -> Bool)?

    /// How the list is ordered. Device Hub offers the same choice from its toolbar.
    enum Sort: String, CaseIterable {
        case name = "Name"
        case serial = "Serial"
        case state = "Status"
    }

    var sort: Sort = .name {
        didSet { if sort != oldValue { applyFilter() } }
    }

    private(set) var devices: [AdbDevice] = []
    /// What a row is. Device Hub groups its list under "Available" and "Unavailable" headers,
    /// so the table is a flat list of headers and devices rather than of devices alone.
    private enum Row {
        case header(String)
        case device(AdbDevice)
        /// An emulator the app is starting: shown under Emulators with a spinner until adb lists
        /// it (a `.device` row with the same serial replaces it) or the launch fails.
        case launching(serial: String, name: String, phase: String)
    }

    private var rows: [Row] = []
    private var filtered: [AdbDevice] = []
    /// Android version per serial, fetched once per device and cached. Device Hub shows the OS
    /// version right-aligned on every row, and one getprop per device per poll would be absurd.
    private var versions: [String: String] = [:]
    /// AVD name per emulator serial, fetched once — the row reads "Emulator · <name>", which is
    /// what a person calls it, rather than the sdk_gphone model string.
    private var avdNames: [String: String] = [:]
    /// Emulators being started from "+ Emulator", by the serial they will have.
    private var launching: [String: (name: String, phase: String)] = [:]

    /// The name the row shows for a device — the AVD name for an emulator once known. The app
    /// titles its window with this, so window and row agree.
    func friendlyName(for device: AdbDevice) -> String {
        guard device.isEmulator, let avd = avdNames[device.serial], !avd.isEmpty else {
            return device.displayName
        }
        return "Emulator · \(avd)"
    }
    private var selectedSerial: String?
    /// Set while we are rebuilding the table ourselves. `reloadData()` drops the selection and
    /// AppKit reports that as a user selection change — which nils `selectedSerial` before the
    /// restore below can read it, silently clearing the selection every poll.
    private var isReloading = false

    private let search = NSSearchField()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        // A literal colour, not a semantic one. NSColor.windowBackgroundColor and friends have an
        // inactive variant that macOS tints warmer when the window loses key, so a pane using one
        // and a pane using another visibly drift apart on focus change. #FAFAFA is what
        // ~/rplay-hub measured off Device Hub's own sidebar.
        wantsLayer = true
        layer?.backgroundColor = Palette.pane.cgColor

        search.placeholderString = "Search"
        search.target = self
        search.action = #selector(searchChanged)
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("device"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.style = .inset
        // Pane colour taken from ~/rplay-hub, so the two apps read as one family.
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255,
                                         blue: 0xFA / 255, alpha: 1).cgColor
        tableView.backgroundColor = .clear     // let the pane colour show through
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.menu = rowMenu()

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        // Overlay, not legacy. A permanently visible scroller drew a grey bar down the sidebar's
        // right edge whatever the system-wide scrollbar setting is, which read as a broken
        // divider rather than as a scroller.
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(search)
        addSubview(scroll)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    /// The row's context menu. Exposed because the device commands that used to live on the
    /// mirror pane get appended to it — they act on the device, so this is where they belong.
    private(set) var rowContextMenu = NSMenu()

    private func rowMenu() -> NSMenu {
        let menu = rowContextMenu
        menu.delegate = self          // retitle the toggle just before the menu opens
        menu.removeAllItems()
        // One entry that toggles — its title is set in menuNeedsUpdate from the live state.
        menu.addItem(withTitle: "Start Screen Mirroring", action: #selector(toggleMirrorFromMenu),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Desktop Mode", action: #selector(desktopModeFromMenu),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Files in Finder", action: #selector(showInFinderFromMenu),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Install Companion App", action: #selector(installCompanionFromMenu),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Serial", action: #selector(copySerial), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Disconnect", action: #selector(disconnectFromMenu),
                     keyEquivalent: "").target = self
        return menu
    }

    /// Append the mirror's device commands under a separator. Their target is the mirror view,
    /// so validation and dispatch stay where they were.
    func appendDeviceCommands(from menu: NSMenu) {
        guard !menu.items.isEmpty else { return }
        rowContextMenu.addItem(.separator())
        for item in menu.items {
            menu.removeItem(item)          // an NSMenuItem belongs to one menu at a time
            rowContextMenu.addItem(item)
        }
    }

    // MARK: - data

    func update(devices: [AdbDevice], note: String) {
        statusLabel.stringValue = note
        // The poll fires every couple of seconds and the answer is nearly always identical.
        // Reloading anyway costs a selection round trip and makes the rows flicker.
        guard devices != self.devices else { return }
        self.devices = devices

        let keep = selectedSerial
        isReloading = true
        applyFilter()
        if let serial = keep, filtered.contains(where: { $0.serial == serial }) {
            select(serial: serial)
            selectedSerial = serial
        } else if keep != nil {
            selectedSerial = nil          // the device really did go away
            onSelect?(nil)
        }
        isReloading = false
    }

    /// Show (or update) a "starting…" row for an emulator the app is launching. The AVD name is
    /// remembered for the serial, so the real row reads "Emulator · <name>" the moment it appears
    /// rather than after a getprop round trip.
    func setLaunching(serial: String, avdName: String, phase: String) {
        launching[serial] = (avdName, phase)
        avdNames[serial] = avdName
        rebuildKeepingSelection()
    }

    func clearLaunching(serial: String) {
        guard launching.removeValue(forKey: serial) != nil else { return }
        rebuildKeepingSelection()
    }

    /// Rebuild the rows for a change that is not a new device list, keeping the selection.
    private func rebuildKeepingSelection() {
        let keep = selectedSerial
        isReloading = true
        applyFilter()
        if let serial = keep, filtered.contains(where: { $0.serial == serial }) {
            select(serial: serial)
            selectedSerial = serial
        }
        isReloading = false
    }

    /// Select a row by serial, as if the user had clicked it.
    func select(serial: String) {
        guard let row = rows.firstIndex(where: {
            if case .device(let d) = $0 { return d.serial == serial }
            return false
        }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
    }

    var selected: AdbDevice? {
        guard let serial = selectedSerial else { return nil }
        return devices.first { $0.serial == serial }
    }

    @objc private func searchChanged() { rebuildKeepingSelection() }

    /// One getprop per device we have not seen before, off the main queue. An emulator also
    /// gets asked for its AVD name (ro.boot.qemu.avd_name; older images use ro.kernel.qemu.*).
    private func loadMissingVersions() {
        for device in devices where device.isReady && versions[device.serial] == nil {
            let serial = device.serial
            versions[serial] = ""        // claim it, so the next poll does not queue a second
            let wantsAvdName = device.isEmulator && avdNames[serial] == nil
            if wantsAvdName { avdNames[serial] = "" }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let release = (try? Adb.getprop(serial, "ro.build.version.release")) ?? ""
                var avd = ""
                if wantsAvdName {
                    avd = (try? Adb.getprop(serial, "ro.boot.qemu.avd_name")) ?? ""
                    if avd.isEmpty { avd = (try? Adb.getprop(serial, "ro.kernel.qemu.avd_name")) ?? "" }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !release.isEmpty { self.versions[serial] = release }
                    if !avd.isEmpty { self.avdNames[serial] = avd }
                    if !release.isEmpty || !avd.isEmpty { self.tableView.reloadData() }
                    if !avd.isEmpty, self.selectedSerial == serial,
                       let device = self.devices.first(where: { $0.serial == serial }) {
                        self.onSelect?(device)
                    }
                }
            }
        }
    }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        loadMissingVersions()
        var result = query.isEmpty ? devices : devices.filter {
            $0.displayName.lowercased().contains(query) || $0.serial.lowercased().contains(query)
        }
        switch sort {
        case .name:   result.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
        case .serial: result.sort { $0.serial < $1.serial }
        // Ready devices first — the ones you can actually do anything with.
        case .state:  result.sort {
            $0.isReady == $1.isReady ? $0.displayName.lowercased() < $1.displayName.lowercased()
                                     : $0.isReady
        }
        }
        filtered = result
        // Rebuild the flat row list: real devices first under their header, then emulators
        // under theirs (as Device Hub sets simulators apart), then whatever is not ready.
        let available = result.filter { $0.isReady && !$0.isEmulator }
        let emulators = result.filter { $0.isReady && $0.isEmulator }
        // adb lists an emulator we are starting as `offline` for a few seconds once adbd is up
        // and before it is usable; the "starting…" row stands in for that, not an Unavailable
        // entry telling the user to reseat a cable.
        let unavailable = result.filter { !$0.isReady && launching[$0.serial] == nil }
        var built: [Row] = []
        if !available.isEmpty {
            built.append(.header("Available"))
            built.append(contentsOf: available.map { Row.device($0) })
        }
        // An emulator still starting sits under the same header; once adb lists its serial the
        // real row takes over (the caller clears the launch entry when it hosts it).
        let starting = launching
            .filter { serial, _ in !result.contains { $0.serial == serial && $0.isReady } }
            .sorted { $0.key < $1.key }
        if !emulators.isEmpty || !starting.isEmpty {
            built.append(.header("Emulators"))
            built.append(contentsOf: emulators.map { Row.device($0) })
            built.append(contentsOf: starting.map {
                Row.launching(serial: $0.key, name: $0.value.name, phase: $0.value.phase)
            })
        }
        if !unavailable.isEmpty {
            built.append(.header("Unavailable"))
            built.append(contentsOf: unavailable.map { Row.device($0) })
        }
        rows = built
        tableView.reloadData()
    }

    @objc private func rowDoubleClicked() {
        guard let device = device(at: tableView.clickedRow) else { return }
        onMirror?(device)
    }

    @objc private func showInFinderFromMenu() {
        if let device = clickedOrSelected() { onShowInFinder?(device) }
    }

    @objc private func installCompanionFromMenu() {
        if let device = clickedOrSelected() { onInstallCompanion?(device) }
    }

    @objc private func desktopModeFromMenu() {
        if let device = clickedOrSelected() { onDesktopMode?(device) }
    }

    @objc private func toggleMirrorFromMenu() {
        if isMirroring?() == true {
            onStopMirror?()
        } else if let device = clickedOrSelected() {
            onMirror?(device)
        }
    }

    /// Retitle the one toggle entry to match the live state, just before the menu shows. Done via
    /// the menu delegate (menuNeedsUpdate) rather than validateMenuItem — the latter is not reliably
    /// called for a table's context menu, which is why the title looked stuck on "Start".
    func menuNeedsUpdate(_ menu: NSMenu) {
        let live = isMirroring?() == true
        for item in menu.items where item.action == #selector(toggleMirrorFromMenu) {
            item.title = live ? "Stop Screen Mirroring" : "Start Screen Mirroring"
        }
        // Disconnect is an adb notion; what an emulator row can do is shut the engine down.
        let emulator = clickedOrSelected()?.isEmulator == true
        for item in menu.items where item.action == #selector(disconnectFromMenu) {
            item.title = emulator ? "Shut Down Emulator" : "Disconnect"
        }
    }

    @objc private func mirrorFromMenu() {
        guard let device = clickedOrSelected() else { return }
        onMirror?(device)
    }

    private func clickedOrSelected() -> AdbDevice? {
        device(at: tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow)
    }

    /// Only meaningful for a network device; a USB one comes back on the next poll.
    @objc private func disconnectFromMenu() {
        guard let device = clickedOrSelected() else { return }
        if device.isEmulator { onShutDownEmulator?(device); return }
        DispatchQueue.global(qos: .utility).async { _ = try? Adb.disconnect(device.serial) }
    }

    @objc private func copySerial() {
        guard let device = clickedOrSelected() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(device.serial, forType: .string)
    }
}

extension DeviceSidebar: NSMenuDelegate {}

extension DeviceSidebar: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func device(at row: Int) -> AdbDevice? {
        guard row >= 0, row < rows.count, case .device(let d) = rows[row] else { return nil }
        return d
    }

    /// Headers are labels, not selectable rows.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        device(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 24 }
        return 42
    }

    /// The row for an emulator that is still starting: a spinner where the status dot goes, the
    /// name it will have, and what the launcher is waiting on.
    private func launchingCell(name: String, phase: String) -> NSView {
        let cell = NSTableCellView()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(image: NSImage(systemSymbolName: "desktopcomputer",
                                               accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Emulator · \(name)")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: phase)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(spinner)
        cell.addSubview(glyph)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            spinner.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            spinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            glyph.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 5),
            glyph.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if case .header(let title) = rows[row] {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),
            ])
            return cell
        }
        if case .launching(_, let name, let phase) = rows[row] {
            return launchingCell(name: name, phase: phase)
        }
        guard let device = device(at: row) else { return nil }
        let cell = NSTableCellView()

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = statusColor(device).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(image: NSImage(
            systemSymbolName: symbol(for: device),
            accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: friendlyName(for: device))
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: subtitle(device))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        // The OS version, right-aligned — Device Hub puts it there on every row.
        let version = NSTextField(labelWithString: versions[device.serial] ?? "")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.alignment = .right
        version.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(dot)
        cell.addSubview(glyph)
        cell.addSubview(text)
        cell.addSubview(version)
        NSLayoutConstraint.activate([
            version.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            version.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            glyph.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),

            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: version.leadingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        guard let device = device(at: tableView.selectedRow) else {
            selectedSerial = nil
            onSelect?(nil)
            return
        }
        selectedSerial = device.serial
        onSelect?(device)
    }

    private func statusColor(_ device: AdbDevice) -> NSColor {
        switch device.state {
        case "device":       return .systemGreen
        case "unauthorized": return .systemOrange
        default:             return .tertiaryLabelColor
        }
    }

    /// What the row says under the name. For the two states the user can act on, say what to do
    /// rather than repeating adb's own word for it.
    private func subtitle(_ device: AdbDevice) -> String {
        switch device.state {
        case "device":       return device.serial
        case "unauthorized": return "Accept the USB debugging prompt on the device"
        case "offline":      return device.isEmulator ? "Offline — still booting"
                                                      : "Offline — reconnect the cable"
        default:             return device.state
        }
    }

    private func symbol(for device: AdbDevice) -> String {
        if device.isEmulator { return "desktopcomputer" }
        let name = (device.model ?? "").lowercased()
        if name.contains("tab") || name.contains("pad") { return "ipad" }
        if name.contains("watch") { return "applewatch" }
        if name.contains("tv") { return "appletv" }
        return "iphone"
    }
}
