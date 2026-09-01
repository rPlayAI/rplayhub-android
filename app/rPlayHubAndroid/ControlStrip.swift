//
//  ControlStrip.swift
//  The buttons under the screen — Back, Home, Overview, and the rest.
//
//  Under the picture rather than in a side pane, because they act on the picture. Android's three
//  navigation buttons are the ones that have no mouse equivalent at all: there is nowhere to click
//  for Back on a gesture-navigation device, so without these the mirror is half usable.
//

import AppKit

final class ControlStrip: NSView {
    private static let buttonWidth: CGFloat = 30
    private static let buttonSpacing: CGFloat = 14

    /// One control's width — the unit a window can grow by to make room beside the picture.
    static var controlWidth: CGFloat { buttonWidth }

    /// The width the toolbar actually needs: every button, the gaps between them, and a margin.
    /// A window showing this strip should be at least this wide or the buttons get cramped.
    var minimumContentWidth: CGFloat {
        let n = CGFloat(buttons.count)
        guard n > 0 else { return 0 }
        return n * Self.buttonWidth + (n - 1) * Self.buttonSpacing + 28
    }

    enum Action {
        case back, home, overview, power, volumeUp, volumeDown, rotate, screenshot, record
    }

    var onAction: ((Action) -> Void)?

    private var buttons: [NSButton] = []
    private var isEnabledForSession = false

    private static let items: [(Action, String, String)] = [
        (.back,       "chevron.backward",       "Back"),
        (.home,       "circle",                 "Home"),
        (.overview,   "square",                 "Overview"),
        (.volumeDown, "speaker.wave.1",         "Volume Down"),
        (.volumeUp,   "speaker.wave.3",         "Volume Up"),
        (.power,      "power",                  "Power"),
        (.rotate,     "rotate.right",           "Rotate"),
        (.screenshot, "camera",                 "Screenshot"),
        (.record,     "record.circle",          "Record Screen"),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        var views: [NSView] = []
        for (index, item) in Self.items.enumerated() {
            let b = NSButton()
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.image = NSImage(systemSymbolName: item.1, accessibilityDescription: item.2)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            b.imagePosition = .imageOnly
            // A square hit target rather than whatever the glyph happens to measure — the
            // navigation buttons are the ones people aim at repeatedly.
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.toolTip = item.2
            b.target = self
            b.tag = index
            b.action = #selector(hit(_:))
            b.contentTintColor = .secondaryLabelColor
            b.isEnabled = false
            buttons.append(b)
            views.append(b)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = Self.buttonSpacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])

        // A hairline above, so the strip reads as a toolbar under the picture rather than as
        // buttons floating in the same space as the screen.
        wantsLayer = true
        layer?.backgroundColor = Palette.canvas.cgColor   // continuous with the picture above
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private let separator = NSView()

    /// Reflect recording state in the button, so it says what pressing it will do next. The red
    /// tint is the only colour in the strip, which is the point — a recording left running is
    /// expensive and easy to forget.
    func setRecording(_ recording: Bool) {
        guard let index = Self.items.firstIndex(where: { $0.0 == .record }),
              index < buttons.count else { return }
        let b = buttons[index]
        let symbol = recording ? "stop.circle.fill" : "record.circle"
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Record")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        b.contentTintColor = recording ? .systemRed : .secondaryLabelColor
        b.toolTip = recording ? "Stop Recording" : "Record Screen"
    }

    @objc private func hit(_ sender: NSButton) {
        guard sender.tag < Self.items.count else { return }
        onAction?(Self.items[sender.tag].0)
    }

    func setSessionActive(_ active: Bool) {
        isEnabledForSession = active
        for b in buttons {
            b.isEnabled = active
            b.contentTintColor = active ? .labelColor : .tertiaryLabelColor
        }
    }
}
