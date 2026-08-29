//
//  IconTabBar.swift
//  Device Hub's three title-bar icon tabs — Settings, Report, Info.
//
//  Hand-rolled rather than an NSSegmentedControl, for one reason that is not cosmetic taste:
//  a segmented control paints its selection with the system accent colour, which made the active
//  tab a solid blue circle where Device Hub's is a soft grey capsule. AppKit exposes no way to
//  restyle that — no per-segment background, no selection colour — so matching it means drawing
//  it. Compared side by side against Device Hub's own title bar at 4x.
//
//  The other thing this gets right for free: Device Hub re-selecting the ALREADY-active tab
//  collapses the whole inspector. A segmented control had to be coaxed into reporting that with
//  `.selectAny` plus a hand-kept shadow copy of what was selected, because `.selectOne` swallows
//  a click on the current segment. Here every click simply reports its index.
//

import AppKit

final class IconTabBar: NSView {
    /// Called with the clicked index, whether or not it was already active — the caller decides
    /// what a re-click means (Device Hub collapses the pane).
    var onSelect: ((Int) -> Void)?

    /// Which tab is lit, or nil while the inspector is collapsed — Device Hub shows no
    /// highlighted icon at all in that state.
    var selected: Int? {
        didSet { if selected != oldValue { needsLayout = true; needsDisplay = true } }
    }

    private var buttons: [NSButton] = []
    private let highlight = CALayer()
    private static let itemWidth: CGFloat = 36
    private static let itemHeight: CGFloat = 28

    init(icons: [(symbol: String, label: String)]) {
        super.init(frame: .zero)
        wantsLayer = true
        // A circle, not a rounded rectangle -- Device Hub's active tab sits on a round grey
        // disc, seen by cropping its title bar at 4x. Set in layout(), where the height is known.
        // Sampled off Device Hub's own active tab: a light grey capsule, not the accent colour.
        highlight.backgroundColor = NSColor(srgbRed: 0xE6 / 255, green: 0xE6 / 255,
                                            blue: 0xE6 / 255, alpha: 1).cgColor
        layer?.addSublayer(highlight)

        for (i, icon) in icons.enumerated() {
            let b = NSButton()
            b.bezelStyle = .inline
            b.isBordered = false
            // Device Hub's glyphs measure 19px tall with their centres ~35px apart, both read off
            // its title bar -- noticeably larger than a default toolbar glyph. 17pt lands there;
            // itemWidth below carries the spacing.
            b.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.label)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            b.imagePosition = .imageOnly
            b.toolTip = icon.label
            b.target = self
            b.tag = i
            b.action = #selector(tapped(_:))
            b.contentTintColor = .secondaryLabelColor
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            buttons.append(b)
        }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant:
            Self.itemWidth * CGFloat(icons.count)).isActive = true
        heightAnchor.constraint(equalToConstant: Self.itemHeight).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    override func layout() {
        super.layout()
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: CGFloat(i) * Self.itemWidth, y: 0,
                             width: Self.itemWidth, height: bounds.height)
            // The lit icon darkens as well as gaining the capsule; the rest stay secondary.
            b.contentTintColor = (i == selected) ? .labelColor : .secondaryLabelColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let s = selected {
            highlight.isHidden = false
            // Square, then fully rounded: a disc centred on the item.
            let d = min(Self.itemWidth, bounds.height) - 2
            highlight.frame = NSRect(x: CGFloat(s) * Self.itemWidth + (Self.itemWidth - d) / 2,
                                     y: (bounds.height - d) / 2, width: d, height: d)
            highlight.cornerRadius = d / 2
        } else {
            highlight.isHidden = true
        }
        CATransaction.commit()
    }

    /// Device Hub draws a hairline between adjacent tabs that are not the active one — the same
    /// separated look a segmented control gives, which is why it has to be reproduced here.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        for i in 1..<max(buttons.count, 1) where i != selected && i - 1 != selected {
            let x = CGFloat(i) * Self.itemWidth
            NSRect(x: x, y: 5, width: 1, height: bounds.height - 10).fill()
        }
    }
}
