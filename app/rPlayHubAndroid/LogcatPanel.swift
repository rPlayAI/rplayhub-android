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
    private let bugReportButton = NSButton()
    private let divider = NSBox()
    private let levelPopUp = NSPopUpButton()
    private let processPopUp = NSPopUpButton()
    private let pauseButton = NSButton()
    private let popOutButton = NSButton()

    /// Set on the copy that lives in its own window, so it does not offer to pop itself out
    /// again. Applied through didSet because the window sets it after init, once build() has
    /// already run.
    var isDetached = false {
        didSet { popOutButton.isHidden = isDetached }
    }
    /// Asked to open in a window. The inspector owns the window; the panel only raises the event.
    var onPopOut: (() -> Void)?
    /// While the detached window is up, the inline panel must not also hold a logcat socket open.
    private var suppressed = false

    private var socket: TCPSocket?
    private var thread: Thread?
    private var stopping = false
    private var paused = false
    private var lineCount = 0
    private static let maximumLines = 5000

    /// Filtering happens on the reader thread, so the criteria are guarded and every UI control
    /// writes through `setCriteria`. A line that fails the filter then costs nothing at all —
    /// no main-queue hop, no attributed string, no layout.
    private let stateLock = NSLock()
    private var filter = ""
    /// nil means every process. Otherwise only lines whose "( pid)" matches are kept.
    private var processFilterPID: Int?

    /// Lines that passed the filter and are waiting for the next flush.
    private var pending: [String] = []
    private var flushTimer: Timer?
    /// A burst can outrun the flush; past this the oldest pending lines are dropped rather than
    /// letting the backlog grow without bound.
    private static let maximumPending = 4000
    /// Flush cadence. Fast enough to feel live, slow enough that a 5000-line/second device
    /// costs ten layout passes a second instead of five thousand.
    private static let flushInterval: TimeInterval = 0.1
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
        textView.backgroundColor = Palette.canvas
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        bugReportButton.title = "Bug Report"
        bugReportButton.bezelStyle = .rounded
        bugReportButton.controlSize = .small
        bugReportButton.target = self
        bugReportButton.action = #selector(bugReportTapped)

        processPopUp.controlSize = .small
        processPopUp.target = self
        processPopUp.action = #selector(processChanged)
        processPopUp.addItem(withTitle: "All processes")

        popOutButton.title = "Open in Window"
        popOutButton.bezelStyle = .rounded
        popOutButton.controlSize = .small
        popOutButton.target = self
        popOutButton.action = #selector(popOutTapped)
        popOutButton.isHidden = isDetached

        let bar = NSStackView(views: [pauseButton, clearButton, bugReportButton, popOutButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        // Filter along the bottom, behind the hairline, as the Apps tab and the iOS hub have it.
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Everything that narrows what you see lives together along the bottom: level, process,
        // then the text filter. The top bar is left with the actions.
        let filterRow = NSStackView(views: [levelPopUp, processPopUp, filterField])
        filterRow.orientation = .horizontal
        filterRow.spacing = 6
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        // An NSPopUpButton sizes itself to its widest menu item, and package names are long
        // enough to swallow the whole row. Cap it and let the text field take the slack.
        processPopUp.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        filterField.setContentHuggingPriority(.init(1), for: .horizontal)

        // The log gets the whole pane. Everything else — the actions, then the three filtering
        // controls — sits below the hairline, in two rows because the inspector is narrow enough
        // that seven controls on one line would clip.
        for v in [scroll, divider, bar, filterRow] { addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -6),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            divider.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: filterRow.topAnchor, constant: -6),

            // The popup yields first, but the search field still needs a floor or a long package
            // name squeezes it down to just its magnifier.
            processPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            filterRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            filterRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            filterRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    /// `adb bugreport` in the form that survives a flaky link: `bugreportz` builds the zip on the
    /// device and prints where it put it, then we pull that one file. Generating it takes minutes
    /// on a real device, so the whole thing runs off the main queue and the button stays disabled
    /// meanwhile — there is no progress to report until the device answers.
    @objc private func bugReportTapped() {
        guard let serial else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bugreport.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        bugReportButton.isEnabled = false
        bugReportButton.title = "Bug Report…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message: String
            do {
                // Ten minutes: a first bugreport on a busy device genuinely can take that long,
                // and the read timeout is per-read idle time, not a total budget.
                let out = try Adb.shell(serial, "bugreportz", timeout: 600)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // "OK:/data/user_de/0/com.android.shell/files/bugreports/bugreport-...zip"
                guard let range = out.range(of: "OK:") else {
                    throw NSError(domain: "bugreport", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                                out.isEmpty ? "no output from bugreportz" : out])
                }
                let remote = String(out[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Adb.pull(serial, remotePath: remote, localPath: destination.path)
                // The device keeps its copy otherwise, and they are tens of megabytes.
                _ = try? Adb.shell(serial, "rm -f '\(remote)'")
                message = "Saved \(destination.lastPathComponent)"
            } catch {
                message = "Bug report failed: \(error.localizedDescription)"
            }
            let saved = message.hasPrefix("Saved")
            DispatchQueue.main.async {
                guard let self else { return }
                self.bugReportButton.isEnabled = true
                self.bugReportButton.title = "Bug Report"
                if saved { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                self.append("--- \(message)")
            }
        }
    }

    // MARK: - streaming

    private func start() {
        guard let serial, socket == nil, !suppressed else { return }
        stopping = false
        reloadProcesses()
        startFlushing()
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
                        self.enqueue(line)
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
        flushTimer?.invalidate()
        flushTimer = nil
        stateLock.lock(); pending.removeAll(); stateLock.unlock()
    }

    private func startFlushing() {
        guard flushTimer == nil else { return }
        // .common so the log keeps updating while a menu is open or the split view is dragged.
        let t = Timer(timeInterval: Self.flushInterval, target: self,
                      selector: #selector(flushPending), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    /// Called on the reader thread for every line the device produces. Filtering happens here
    /// rather than in logcat's own arguments, so changing the filter does not mean tearing down
    /// the stream and losing everything already collected — and rejected lines never reach the
    /// main thread at all, which is what keeps a chatty device from freezing the app.
    private func enqueue(_ line: String) {
        stateLock.lock()
        let dropped = paused
            || (minimumLevel > 0 && (Self.levels.firstIndex(of: line.first.map(String.init) ?? "V") ?? 0) < minimumLevel)
            || (processFilterPID.map { Self.pid(of: line) != $0 } ?? false)
            || (!filter.isEmpty && !line.lowercased().contains(filter))
        if !dropped {
            pending.append(line)
            if pending.count > Self.maximumPending {
                pending.removeFirst(pending.count - Self.maximumPending)
            }
        }
        stateLock.unlock()
    }

    /// Drain whatever the reader has collected into the text view in one write. Everything that
    /// was per-line before — the scroll-position query, the storage append, the trim check — now
    /// happens once per batch. The scroll query in particular reads `textView.frame.height`,
    /// which forces the layout manager over the whole document; doing that per line is what made
    /// a busy device unusable.
    @objc private func flushPending() {
        stateLock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        stateLock.unlock()
        guard !batch.isEmpty, let storage = textView.textStorage else { return }

        let atBottom = isScrolledToBottom()
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let block = NSMutableAttributedString()
        for line in batch {
            let color: NSColor
            switch line.first {
            case "E", "F": color = .systemRed
            case "W":      color = .systemOrange
            case "I":      color = .labelColor
            default:       color = .secondaryLabelColor
            }
            block.append(NSAttributedString(string: line + "\n",
                                            attributes: [.font: font, .foregroundColor: color]))
        }
        storage.append(block)
        lineCount += batch.count
        if lineCount > Self.maximumLines { trim() }
        if atBottom { textView.scrollToEndOfDocument(nil) }
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
        stateLock.lock(); paused.toggle(); let now = paused; stateLock.unlock()
        pauseButton.title = now ? "Resume" : "Pause"
    }

    @objc private func popOutTapped() { onPopOut?() }

    @objc private func processChanged() {
        let tag = processPopUp.selectedItem?.tag ?? 0
        stateLock.lock(); processFilterPID = tag > 0 ? tag : nil; stateLock.unlock()
    }

    /// Stop streaming and refuse to start again — used while the detached window owns the stream.
    func setSuppressed(_ value: Bool) {
        guard suppressed != value else { return }
        suppressed = value
        if value { stop() } else if serial != nil, !isHidden { start() }
    }

    /// The device's app processes, for the process filter. Kernel threads and bare binaries are
    /// dropped: a package name is the only thing anybody filters logcat by.
    private func reloadProcesses() {
        guard let serial else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = (try? Adb.shell(serial, "ps -A -o PID,NAME")) ?? ""
            var found: [(pid: Int, name: String)] = []
            for line in out.components(separatedBy: "\n").dropFirst() {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
                let name = String(parts[1])
                guard name.contains("."), !name.hasPrefix("[") else { continue }
                found.append((pid, name))
            }
            found.sort { $0.name.lowercased() < $1.name.lowercased() }
            DispatchQueue.main.async { self?.applyProcesses(found) }
        }
    }

    private func applyProcesses(_ list: [(pid: Int, name: String)]) {
        let previous = processFilterPID
        processPopUp.removeAllItems()
        processPopUp.addItem(withTitle: "All processes")
        processPopUp.lastItem?.tag = 0
        for entry in list {
            processPopUp.addItem(withTitle: "\(entry.name)  (\(entry.pid))")
            processPopUp.lastItem?.tag = entry.pid
        }
        // Keep the user's choice across a refresh; if that process died, fall back to all.
        if let previous, let match = processPopUp.itemArray.first(where: { $0.tag == previous }) {
            processPopUp.select(match)
        } else {
            processPopUp.selectItem(at: 0)
            processFilterPID = nil
        }
    }

    /// "D/Tag ( 1234): message" — the pid sits in the first parenthesised group.
    private static func pid(of line: String) -> Int? {
        guard let open = line.firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")") else { return nil }
        return Int(line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    @objc private func filterChanged() {
        let text = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        stateLock.lock(); filter = text; stateLock.unlock()
    }

    @objc private func levelChanged() {
        let level = levelPopUp.indexOfSelectedItem
        stateLock.lock(); minimumLevel = level; stateLock.unlock()
    }

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
