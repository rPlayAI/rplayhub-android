//
//  ScreenTabBar.swift
//  Device Hub's tab bar in the center panel — what its "Open in New Tab" adds.
//
//  In Device Hub a tab is a whole window (its Window menu carries the standard tabbing items),
//  and macOS 26 draws the tab bar between the sidebar and inspector separators, so it reads as a
//  bar across the center panel with the sidebar and inspector staying put. This app has one
//  window and one stage, so the bar is drawn here instead and a tab is a selection slot: it
//  remembers a device, and choosing a tab puts that device on the stage. The first tab is the
//  embedded view and always exists; the bar only shows once there is a second.
//
//  The look follows Device Hub's: a grey capsule holding equal segments, the current one white,
//  a close mark on it while the pointer is over the bar, and "+" at the right end.
//

import AppKit

final class ScreenTabBar: NSView {
    struct Tab: Equatable {
        var serial: String
        var title: String
    }

    static let height: CGFloat = 28

    var tabs: [Tab] = [] { didSet { if tabs != oldValue { needsLayout = true; needsDisplay = true } } }
    var selectedIndex = 0 { didSet { if selectedIndex != oldValue { needsLayout = true; needsDisplay = true } } }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let addButton = NSButton()
    private let closeButton = NSButton()
    private var hovering = false { didSet { if hovering != oldValue { needsLayout = true } } }
    private var tracking: NSTrackingArea?

    private static let addWidth: CGFloat = 28
    private static let gap: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        let small = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        for (button, symbol, action) in [(addButton, "plus", #selector(addTapped)),
                                         (closeButton, "xmark", #selector(closeTapped))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(small)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            addSubview(button)
        }
        addButton.toolTip = "Open Screen in New Tab"
        closeButton.toolTip = "Close Tab"
        closeButton.isHidden = true
    }

    override var isFlipped: Bool { true }

    // MARK: - geometry

    /// The capsule: everything but the "+" at the right end.
    private var pillRect: CGRect {
        CGRect(x: 0, y: 0, width: max(0, bounds.width - Self.addWidth - Self.gap), height: bounds.height)
    }

    private func segmentRect(_ index: Int) -> CGRect {
        let pill = pillRect
        let count = CGFloat(max(1, tabs.count))
        let width = pill.width / count
        return CGRect(x: pill.minX + width * CGFloat(index), y: pill.minY, width: width, height: pill.height)
    }

    override func layout() {
        super.layout()
        addButton.frame = CGRect(x: bounds.width - Self.addWidth, y: 0, width: Self.addWidth, height: bounds.height)
        let showClose = hovering && tabs.count > 1 && tabs.indices.contains(selectedIndex)
        closeButton.isHidden = !showClose
        if showClose {
            let seg = segmentRect(selectedIndex)
            closeButton.frame = CGRect(x: seg.minX + 6, y: (seg.height - 20) / 2, width: 20, height: 20)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        let pill = pillRect
        guard pill.width > 0 else { return }
        NSColor.systemGray.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()

        for (i, tab) in tabs.enumerated() {
            let seg = segmentRect(i)
            let selected = i == selectedIndex
            if selected {
                let face = seg.insetBy(dx: 2, dy: 2)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                NSColor.controlBackgroundColor.setFill()
                NSBezierPath(roundedRect: face, xRadius: 7, yRadius: 7).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: selected ? .medium : .regular),
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]
            let text = tab.title as NSString
            let size = text.size(withAttributes: attributes)
            // Room for the close mark on the left so the title does not run under it.
            let inset: CGFloat = selected ? 28 : 10
            let box = CGRect(x: seg.minX + inset, y: seg.midY - size.height / 2,
                             width: max(0, seg.width - inset * 2), height: size.height)
            text.draw(in: box, withAttributes: attributes)
        }
    }

    // MARK: - input

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard pillRect.contains(p) else { super.mouseDown(with: event); return }
        for i in tabs.indices where segmentRect(i).contains(p) {
            if i != selectedIndex { onSelect?(i) }
            return
        }
    }

    @objc private func addTapped() { onAdd?() }
    @objc private func closeTapped() { onClose?(selectedIndex) }
}
