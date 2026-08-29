//
//  LogcatPanel.swift
//  Agent log and logcat, in a scrolling monospaced view.
//
//  The agent's own log is the thing worth having here: when mirroring fails on a particular
//  device the reason is almost always a line it printed to stdout before exiting, and that
//  stdout is our shell socket rather than anything logcat would show.
//

import AppKit

final class LogcatPanel: NSView {
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private var lineCount = 0
    private static let maximumLines = 2000

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func append(_ line: String) {
        let atBottom = isScrolledToBottom()
        textView.textStorage?.append(NSAttributedString(
            string: line + "\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        lineCount += 1
        if lineCount > Self.maximumLines { trim() }
        // Follow the tail only when the user is already there — scrolling away to read something
        // and being yanked back on the next line is the whole reason log views get closed.
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    func clear() {
        textView.string = ""
        lineCount = 0
    }

    private func isScrolledToBottom() -> Bool {
        let visible = scroll.contentView.documentVisibleRect
        let height = textView.frame.height
        return visible.maxY >= height - 20
    }

    private func trim() {
        guard let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var cut = 0
        var removed = 0
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
