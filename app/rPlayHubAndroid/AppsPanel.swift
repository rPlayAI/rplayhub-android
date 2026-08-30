//
//  AppsPanel.swift
//  The inspector's Apps tab: what is installed, and Launch / Stop / Uninstall / Install APK.
//
//  Backed by `pm list packages` and friends. Labels are deliberately not fetched up front — that
//  costs one `dumpsys package` per app, and this device has 402 of them, so opening the tab would
//  take the better part of a minute. The version of the selected row is fetched on demand instead.
//

import AppKit
import UniformTypeIdentifiers

final class AppsPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// Set by the owner whenever the session changes.
    var serial: String? {
        didSet {
            guard serial != oldValue else { return }
            packages = []
            filtered = []
            table.reloadData()
            loaded = false
            status.stringValue = serial == nil ? "No device." : ""
            if serial != nil, !isHidden { refresh() }
        }
    }

    private var packages: [Adb.Package] = []
    private var filtered: [Adb.Package] = []
    private var loaded = false
    private var showSystem = false

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let search = NSSearchField()
    private let divider = NSBox()
    private let status = NSTextField(labelWithString: "")
    private let systemToggle = NSButton(checkboxWithTitle: "System apps", target: nil, action: nil)
    private let installButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isHidden: Bool {
        didSet { if !isHidden, !loaded, serial != nil { refresh() } }
    }

    private func build() {
        search.placeholderString = "Filter"
        search.target = self
        search.action = #selector(applyFilter)
        search.translatesAutoresizingMaskIntoConstraints = false

        systemToggle.target = self
        systemToggle.action = #selector(toggleSystem)
        systemToggle.font = .systemFont(ofSize: 11)
        systemToggle.translatesAutoresizingMaskIntoConstraints = false

        installButton.title = "Install APK…"
        installButton.bezelStyle = .rounded
        installButton.controlSize = .small
        installButton.target = self
        installButton.action = #selector(installApk)
        installButton.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("app"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.menu = rowMenu()
        table.target = self
        table.doubleAction = #selector(launchSelected)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        // The hairline Device Hub draws above its bottom Filter row, as the iOS hub's Apps tab
        // has it: list first, then the +/- row and status, then the filter along the bottom.
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Same shape as the Logcat tab: the list owns the pane, and everything that acts on it
        // or narrows it sits below the hairline — actions first, then the filter.
        for v in [search, systemToggle, installButton, scroll, status, divider] { addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -6),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            divider.bottomAnchor.constraint(equalTo: systemToggle.topAnchor, constant: -6),

            systemToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            systemToggle.bottomAnchor.constraint(equalTo: search.topAnchor, constant: -6),

            installButton.centerYAnchor.constraint(equalTo: systemToggle.centerYAnchor),
            installButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            search.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Launch", #selector(launchSelected)),
                                ("Force Stop", #selector(stopSelected)),
                                ("Copy Package Name", #selector(copySelected)),
                                ("Uninstall…", #selector(uninstallSelected))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: - loading

    func refresh() {
        guard let serial else { return }
        status.stringValue = "Loading…"
        let wantSystem = showSystem
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = (try? Adb.packages(serial, includeSystem: wantSystem)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.serial == serial else { return }
                self.packages = result
                self.loaded = true
                self.applyFilter()
                self.status.stringValue = "\(result.count) package\(result.count == 1 ? "" : "s")"
            }
        }
    }

    @objc private func toggleSystem() {
        showSystem = systemToggle.state == .on
        refresh()
    }

    @objc private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = query.isEmpty ? packages : packages.filter { $0.id.lowercased().contains(query) }
        table.reloadData()
    }

    private var selectedPackage: Adb.Package? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < filtered.count else { return nil }
        return filtered[row]
    }

    // MARK: - actions

    /// Every one of these is a round trip, so none of them run on the main queue.
    private func run(_ label: String, _ work: @escaping (String) throws -> Void) {
        guard let serial, let package = selectedPackage else { return }
        status.stringValue = "\(label) \(package.id)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message = "\(label) \(package.id)"
            do { try work(package.id) } catch { message = "\(error)" }
            _ = serial
            DispatchQueue.main.async { self?.status.stringValue = message }
        }
    }

    @objc private func launchSelected() {
        guard let serial else { return }
        run("Launched") { try Adb.launch(serial, package: $0) }
    }

    @objc private func stopSelected() {
        guard let serial else { return }
        run("Stopped") { try Adb.forceStop(serial, package: $0) }
    }

    @objc private func copySelected() {
        guard let package = selectedPackage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(package.id, forType: .string)
        status.stringValue = "Copied \(package.id)"
    }

    @objc private func uninstallSelected() {
        guard let serial, let package = selectedPackage else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(package.id)?"
        alert.informativeText = "This removes the app and its data from the device."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message = "Uninstalled \(package.id)"
            do { try Adb.uninstall(serial, package: package.id) } catch { message = "\(error)" }
            DispatchQueue.main.async {
                self?.status.stringValue = message
                self?.refresh()
            }
        }
    }

    @objc private func installApk() {
        guard let serial else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        status.stringValue = "Installing \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message = "Installed \(url.lastPathComponent)"
            do { try Adb.install(serial, apkPath: url.path) } catch { message = "\(error)" }
            DispatchQueue.main.async {
                self?.status.stringValue = message
                self?.refresh()
            }
        }
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let package = filtered[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: package.id)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = package.isSystem ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        // The APK may not yield an icon at all (see AppIcons), so the slot keeps its width
        // either way and the names stay aligned down the column.
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon

        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        if let serial {
            let wanted = package.id
            AppIcons.icon(serial: serial, package: wanted) { [weak icon, weak self] image in
                // The cell is reused as the list scrolls, so only paint if this view is still
                // showing the package we asked about.
                guard let icon, let self else { return }
                let r = self.table.row(for: icon)
                guard r >= 0, r < self.filtered.count, self.filtered[r].id == wanted else { return }
                icon.image = image
            }
        }
        return cell
    }
}
