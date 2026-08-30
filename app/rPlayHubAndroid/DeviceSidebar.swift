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

    private(set) var devices: [AdbDevice] = []
    private var filtered: [AdbDevice] = []
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

        let header = NSTextField(labelWithString: "Available")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

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
        addSubview(header)
        addSubview(scroll)
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            header.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
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
        menu.removeAllItems()
        menu.addItem(withTitle: "Mirror", action: #selector(mirrorFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Serial", action: #selector(copySerial), keyEquivalent: "")
            .target = self
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
        if let serial = keep, let row = filtered.firstIndex(where: { $0.serial == serial }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            selectedSerial = serial
        } else if keep != nil {
            selectedSerial = nil          // the device really did go away
            onSelect?(nil)
        }
        isReloading = false
    }

    /// Select a row by serial, as if the user had clicked it.
    func select(serial: String) {
        guard let row = filtered.firstIndex(where: { $0.serial == serial }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
    }

    var selected: AdbDevice? {
        guard let serial = selectedSerial else { return nil }
        return devices.first { $0.serial == serial }
    }

    @objc private func searchChanged() {
        let keep = selectedSerial
        isReloading = true
        applyFilter()
        if let serial = keep, let row = filtered.firstIndex(where: { $0.serial == serial }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            selectedSerial = serial
        }
        isReloading = false
    }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = query.isEmpty ? devices : devices.filter {
            $0.displayName.lowercased().contains(query) || $0.serial.lowercased().contains(query)
        }
        tableView.reloadData()
    }

    @objc private func rowDoubleClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < filtered.count else { return }
        onMirror?(filtered[tableView.clickedRow])
    }

    @objc private func mirrorFromMenu() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        onMirror?(filtered[row])
    }

    @objc private func copySerial() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filtered[row].serial, forType: .string)
    }
}

extension DeviceSidebar: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let device = filtered[row]
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

        let name = NSTextField(labelWithString: device.displayName)
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

        cell.addSubview(dot)
        cell.addSubview(glyph)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            glyph.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),

            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else {
            selectedSerial = nil
            onSelect?(nil)
            return
        }
        selectedSerial = filtered[row].serial
        onSelect?(filtered[row])
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
        case "offline":      return "Offline — reconnect the cable"
        default:             return device.state
        }
    }

    private func symbol(for device: AdbDevice) -> String {
        let name = (device.model ?? "").lowercased()
        if name.contains("tab") || name.contains("pad") { return "ipad" }
        if name.contains("watch") { return "applewatch" }
        if name.contains("tv") { return "appletv" }
        return "iphone"
    }
}
