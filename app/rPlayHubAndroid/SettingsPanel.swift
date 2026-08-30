//
//  SettingsPanel.swift
//  The inspector's Settings tab: the device switches worth having beside a mirror.
//
//  All of these are `settings put`, which shell is allowed to do. Chosen for what actually helps
//  while mirroring: seeing where taps land, keeping the screen from sleeping mid-session, and
//  turning animations off so the picture is not mostly transitions.
//

import AppKit

final class SettingsPanel: NSView {
    var serial: String? {
        didSet {
            guard serial != oldValue else { return }
            loaded = false
            if serial != nil, !isHidden { refresh() }
        }
    }

    override var isHidden: Bool {
        didSet { if !isHidden, !loaded, serial != nil { refresh() } }
    }

    /// namespace, key, label, SF Symbol, on-value, off-value
    private struct Toggle {
        let namespace: String, key: String, label: String, icon: String, on: String, off: String
        /// What an unset ("null") value means on the device. The animation scales ship on, so
        /// that stays the default; a developer overlay like the refresh-rate counter ships off.
        var defaultOn: Bool = true
    }

    private static let toggles: [Toggle] = [
        .init(namespace: "system", key: "show_touches", label: "Show taps",
              icon: "hand.tap", on: "1", off: "0"),
        .init(namespace: "system", key: "pointer_location", label: "Pointer location",
              icon: "cursorarrow.motionlines", on: "1", off: "0"),
        // Developer options' "Show refresh rate" — the Hz counter SurfaceFlinger draws in the
        // corner. Off unless somebody turned it on, unlike the animation scales below.
        .init(namespace: "global", key: "show_refresh_rate", label: "Show refresh rate",
              icon: "speedometer", on: "1", off: "0", defaultOn: false),
        .init(namespace: "global", key: "stay_on_while_plugged_in", label: "Stay awake while charging",
              icon: "bolt", on: "7", off: "0"),
        .init(namespace: "global", key: "window_animation_scale", label: "Window animations",
              icon: "macwindow", on: "1", off: "0"),
        .init(namespace: "global", key: "transition_animation_scale", label: "Transition animations",
              icon: "rectangle.2.swap", on: "1", off: "0"),
        .init(namespace: "global", key: "animator_duration_scale", label: "Animator duration",
              icon: "timer", on: "1", off: "0"),
    ]

    private var switches: [NSSwitch] = []
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
        var views: [NSView] = []
        var rows: [NSView] = []
        for (index, toggle) in Self.toggles.enumerated() {
            // Device Hub puts the label on the left and a switch against the trailing edge,
            // not a titled checkbox. Its switches measure 36x18pt; a stock NSSwitch is 54x21,
            // half again as wide, so .mini is the closest match.
            let sw = NSSwitch()
            sw.controlSize = .mini
            sw.target = self
            sw.action = #selector(toggleChanged(_:))
            sw.tag = index
            switches.append(sw)

            let label = NSTextField(labelWithString: toggle.label)
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(200), for: .horizontal)

            // Leading glyph, as Device Hub and the iOS hub both draw. Secondary tint so it
            // reads as a marker for the row rather than competing with the label.
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: toggle.icon, accessibilityDescription: nil)
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 16).isActive = true

            let row = NSStackView(views: [image, label, NSView(), sw])
            row.orientation = .horizontal
            row.spacing = 6
            rows.append(row)
            views.append(row)
        }
        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: views + [status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // The stack aligns leading, so each row has to be told to span the full width or the
        // switch would sit next to its label instead of at the end of the row.
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
    }

    /// Read the current values back, so the boxes reflect the device rather than guessing.
    private func refresh() {
        guard let serial else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // One shell round trip for all of them; six would be slow over wifi adb.
            let query = Self.toggles
                .map { "settings get \($0.namespace) \($0.key)" }
                .joined(separator: "; ")
            let out = (try? Adb.shell(serial, query)) ?? ""
            let values = out.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.serial == serial else { return }
                self.loaded = true
                for (index, toggle) in Self.toggles.enumerated() where index < values.count {
                    let value = values[index]
                    // "null" means unset, so fall back to what the device ships with.
                    let isOn = value == "null" ? toggle.defaultOn : (value != toggle.off)
                    self.switches[index].state = isOn ? .on : .off
                }
            }
        }
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard let serial, sender.tag < Self.toggles.count else { return }
        let toggle = Self.toggles[sender.tag]
        let value = sender.state == .on ? toggle.on : toggle.off
        status.stringValue = "\(toggle.label) → \(value)"
        DispatchQueue.global(qos: .utility).async {
            _ = try? Adb.shell(serial, "settings put \(toggle.namespace) \(toggle.key) \(value)")
        }
    }
}
