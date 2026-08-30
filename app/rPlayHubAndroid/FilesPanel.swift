//
//  FilesPanel.swift
//  The inspector's Files tab: browse the device's filesystem, pull files out.
//
//  Double-click a directory to enter it, a file to pull it to ~/Downloads/rPlayHubAndroid and
//  reveal it in Finder. What is readable depends on who we are: as shell, /sdcard and
//  /data/local/tmp are open, most of /data is not. That is a property of the device, not a bug
//  here, so an unreadable directory says so rather than appearing empty.
//

import AppKit

final class FilesPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var serial: String? {
        didSet {
            guard serial != oldValue else { return }
            entries = []
            table.reloadData()
            loaded = false
            path = "/sdcard"
            status.stringValue = serial == nil ? "No device." : ""
            if serial != nil, !isHidden { refresh() }
        }
    }

    private var path = "/sdcard" { didSet { pathLabel.stringValue = path } }
    private var entries: [Adb.DirEntry] = []
    private var loaded = false

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let pathLabel = NSTextField(labelWithString: "/sdcard")
    private let upButton = NSButton()
    private let status = NSTextField(labelWithString: "")

    /// Where pulled files land. Fixed rather than asked for each time: this tab is for having a
    /// quick look at something, and a save panel per file makes that tedious.
    private static let downloads = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask).first?
        .appendingPathComponent("rPlayHubAndroid")

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
        upButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Up")
        upButton.bezelStyle = .texturedRounded
        upButton.isBordered = false
        upButton.target = self
        upButton.action = #selector(goUp)
        upButton.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.backgroundColor = .clear
        // A hairline under every row, as Device Hub rules its lists.
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = Palette.separator
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.menu = rowMenu()

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

        for v in [upButton, pathLabel, scroll, status] { addSubview(v) }
        NSLayoutConstraint.activate([
            upButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            upButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            upButton.widthAnchor.constraint(equalToConstant: 22),

            pathLabel.centerYAnchor.constraint(equalTo: upButton.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 4),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: upButton.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Save to Downloads", action: #selector(pullSelected),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath),
                     keyEquivalent: "").target = self
        return menu
    }

    // MARK: - navigation

    func refresh() {
        guard let serial else { return }
        let wanted = path
        status.stringValue = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = (try? Adb.list(serial, path: wanted)) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.serial == serial, self.path == wanted else { return }
                self.entries = result
                self.loaded = true
                self.table.reloadData()
                // An empty listing is ambiguous — the directory may be empty, or shell may
                // simply not be allowed to read it. Say which rather than showing nothing.
                self.status.stringValue = result.isEmpty
                    ? "Empty, or not readable as shell."
                    : "\(result.count) item\(result.count == 1 ? "" : "s")"
            }
        }
    }

    @objc private func goUp() {
        guard path != "/" else { return }
        path = (path as NSString).deletingLastPathComponent
        if path.isEmpty { path = "/" }
        refresh()
    }

    private var selectedEntry: Adb.DirEntry? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    private func fullPath(_ entry: Adb.DirEntry) -> String {
        path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
    }

    @objc private func openSelected() {
        guard let entry = selectedEntry else { return }
        // A symlink to a directory is worth following too; `ls` on it will tell us.
        if entry.isDirectory || entry.isLink {
            path = fullPath(entry)
            refresh()
        } else {
            pullSelected()
        }
    }

    @objc private func copyPath() {
        guard let entry = selectedEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullPath(entry), forType: .string)
        status.stringValue = "Copied \(fullPath(entry))"
    }

    @objc private func pullSelected() {
        guard let serial, let entry = selectedEntry, !entry.isDirectory,
              let dir = Self.downloads else { return }
        let remote = fullPath(entry)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(entry.name)
        status.stringValue = "Pulling \(entry.name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message = "Saved to \(local.path)"
            var ok = true
            do {
                try Adb.pull(serial, remotePath: remote, localPath: local.path)
            } catch {
                message = "\(error)"
                ok = false
            }
            DispatchQueue.main.async {
                self?.status.stringValue = message
                if ok { NSWorkspace.shared.activateFileViewerSelecting([local]) }
            }
        }
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()

        let symbol = entry.isDirectory ? "folder" : (entry.isLink ? "arrow.turn.up.right" : "doc")
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol,
                                               accessibilityDescription: nil) ?? NSImage())
        glyph.contentTintColor = entry.isDirectory ? .systemBlue : .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let size = NSTextField(labelWithString: entry.displaySize)
        size.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        size.textColor = .tertiaryLabelColor
        size.alignment = .right
        size.translatesAutoresizingMaskIntoConstraints = false

        for v in [glyph, name, size] { cell.addSubview(v) }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),

            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: size.leadingAnchor, constant: -8),

            size.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            size.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            size.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        return cell
    }
}
