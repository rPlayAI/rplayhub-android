//
//  LogcatPanel.swift
//  The inspector's Logcat tab: the device's log, streamed live.
//
//  This is the tab that makes the tool more than a mirror — scrcpy has no equivalent. It is also
//  where the agent's own log ends up: the agent logs through __android_log_print under the tag
//  `studio.screen.sharing`, NOT to the stdout we read off its shell socket, so logcat is the only
//  place its diagnostics appear. When mirroring misbehaves on a particular device, the reason is
//  here.
//
//  Streamed over a long-lived `exec:logcat` socket rather than polled, and trimmed as it grows —
//  a busy device produces thousands of lines a minute and an unbounded text view will eat the
//  machine.
//

import AppKit

final class LogcatPanel: NSView {
    var serial: String? {
        didSet {
            guard serial != oldValue else { return }
            stop()
            clear()
            if serial != nil, !isHidden { start() }
        }
    }

    /// Only stream while visible. Holding a logcat socket open behind a hidden tab is pure cost.
    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            if isHidden { stop() } else if serial != nil { start() }
        }
    }

    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let filterField = NSSearchField()
    private let levelPopUp = NSPopUpButton()
    private let pauseButton = NSButton()

    private var socket: TCPSocket?
    private var thread: Thread?
    private var stopping = false
    private var paused = false
    private var lineCount = 0
    private static let maximumLines = 5000

    private var filter = ""
    /// logcat's own priority letters, in order.
    private static let levels = ["V", "D", "I", "W", "E"]
    private var minimumLevel = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    deinit { stop() }

    private func build() {
        filterField.placeholderString = "Filter"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.translatesAutoresizingMaskIntoConstraints = false

        levelPopUp.addItems(withTitles: ["Verbose", "Debug", "Info", "Warn", "Error"])
        levelPopUp.selectItem(at: 0)
        levelPopUp.target = self
        levelPopUp.action = #selector(levelChanged)
        levelPopUp.controlSize = .small
        levelPopUp.font = .systemFont(ofSize: 10)
        levelPopUp.translatesAutoresizingMaskIntoConstraints = false

        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton()
        clearButton.title = "Clear"
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView(views: [levelPopUp, pauseButton, clearButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        for v in [filterField, bar, scroll] { addSubview(v) }
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            filterField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            bar.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - streaming

    private func start() {
        guard let serial, socket == nil else { return }
        stopping = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // -v brief keeps each line short enough to read in a narrow pane. No -d: this runs
            // until we close the socket.
            guard let s = try? Adb.shellStream(serial, "logcat -v brief") else {
                DispatchQueue.main.async { self.append("[could not open logcat]") }
                return
            }
            self.socket = s
            var buffer = Data()
            while !self.stopping {
                do {
                    guard let chunk = try s.read() else { continue }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer = buffer.suffix(from: buffer.index(after: nl))
                        guard !line.isEmpty else { continue }
                        DispatchQueue.main.async { self.consider(line) }
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func stop() {
        stopping = true
        socket?.shutdownAndClose()
        socket = nil
    }

    /// Filtering happens here rather than in logcat's own arguments, so changing the filter does
    /// not mean tearing down the stream and losing everything already collected.
    private func consider(_ line: String) {
        guard !paused else { return }
        if minimumLevel > 0 {
            // "D/Tag ( 1234): message" — the priority is the first character.
            let priority = line.first.map(String.init) ?? "V"
            let index = Self.levels.firstIndex(of: priority) ?? 0
            guard index >= minimumLevel else { return }
        }
        if !filter.isEmpty, !line.lowercased().contains(filter) { return }
        append(line)
    }

    private func append(_ line: String) {
        let atBottom = isScrolledToBottom()
        let color: NSColor
        switch line.first {
        case "E", "F": color = .systemRed
        case "W":      color = .systemOrange
        case "I":      color = .labelColor
        default:       color = .secondaryLabelColor
        }
        textView.textStorage?.append(NSAttributedString(
            string: line + "\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: color]))
        lineCount += 1
        if lineCount > Self.maximumLines { trim() }
        // Follow the tail only when already there — scrolling back to read something and being
        // yanked to the bottom on the next line is why log views get closed.
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    func clear() {
        textView.string = ""
        lineCount = 0
    }

    @objc private func clearTapped() {
        // Clear the device's buffer too, so what comes back is genuinely new.
        if let serial { DispatchQueue.global(qos: .utility).async { _ = try? Adb.shell(serial, "logcat -c") } }
        clear()
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseButton.title = paused ? "Resume" : "Pause"
    }

    @objc private func filterChanged() {
        filter = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    }

    @objc private func levelChanged() { minimumLevel = levelPopUp.indexOfSelectedItem }

    private func isScrolledToBottom() -> Bool {
        scroll.contentView.documentVisibleRect.maxY >= textView.frame.height - 24
    }

    private func trim() {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var cut = 0, removed = 0
        while removed < Self.maximumLines / 4 {
            let r = text.range(of: "\n", range: NSRange(location: cut, length: text.length - cut))
            guard r.location != NSNotFound else { break }
            cut = r.location + 1
            removed += 1
        }
        guard cut > 0 else { return }
        storage.deleteCharacters(in: NSRange(location: 0, length: cut))
        lineCount -= removed
    }
}
