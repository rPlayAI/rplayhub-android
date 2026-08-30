//
//  CrashesPanel.swift
//  The inspector's Crashes tab: native tombstones and Java crashes.
//
//  Two sources, because Android keeps them apart. `logcat -b crash` is the ring buffer of Java
//  exceptions — cheap and usually what you want. DropBox holds the system's own durable record,
//  including native tombstones and ANRs, and survives a logcat wipe.
//

import AppKit

final class CrashesPanel: NSView {
    var serial: String? {
        didSet {
            guard serial != oldValue else { return }
            textView.string = ""
            loaded = false
            if serial != nil, !isHidden { refresh() }
        }
    }

    override var isHidden: Bool {
        didSet { if !isHidden, !loaded, serial != nil { refresh() } }
    }

    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let sourcePopUp = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private var loaded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        sourcePopUp.addItems(withTitles: ["Crash buffer", "DropBox (tombstones, ANRs)"])
        sourcePopUp.target = self
        sourcePopUp.action = #selector(refresh)
        sourcePopUp.controlSize = .small
        sourcePopUp.font = .systemFont(ofSize: 10)
        sourcePopUp.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton()
        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.backgroundColor = Palette.canvas
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView(views: [sourcePopUp, refreshButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        for v in [bar, scroll, status] { addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @objc private func refresh() {
        guard let serial else { return }
        let dropbox = sourcePopUp.indexOfSelectedItem == 1
        status.stringValue = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let command = dropbox
                ? "dumpsys dropbox --print | tail -400"
                : "logcat -b crash -d -v brief -t 400"
            let text = (try? Adb.shell(serial, command)) ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, self.serial == serial else { return }
                self.loaded = true
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.textView.string = trimmed.isEmpty ? "Nothing recorded." : trimmed
                let lines = trimmed.isEmpty ? 0 : trimmed.components(separatedBy: "\n").count
                self.status.stringValue = "\(lines) line\(lines == 1 ? "" : "s")"
            }
        }
    }
}
