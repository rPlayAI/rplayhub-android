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

    /// namespace, key, label, on-value, off-value
    private struct Toggle {
        let namespace: String, key: String, label: String, on: String, off: String
    }

    private static let toggles: [Toggle] = [
        .init(namespace: "system", key: "show_touches", label: "Show taps",
              on: "1", off: "0"),
        .init(namespace: "system", key: "pointer_location", label: "Pointer location",
              on: "1", off: "0"),
        .init(namespace: "global", key: "stay_on_while_plugged_in", label: "Stay awake while charging",
              on: "7", off: "0"),
        .init(namespace: "global", key: "window_animation_scale", label: "Window animations",
              on: "1", off: "0"),
        .init(namespace: "global", key: "transition_animation_scale", label: "Transition animations",
              on: "1", off: "0"),
        .init(namespace: "global", key: "animator_duration_scale", label: "Animator duration",
              on: "1", off: "0"),
    ]

    private var checkboxes: [NSButton] = []
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
        for (index, toggle) in Self.toggles.enumerated() {
            let box = NSButton(checkboxWithTitle: toggle.label, target: self,
                               action: #selector(toggleChanged(_:)))
            box.tag = index
            box.font = .systemFont(ofSize: 11)
            checkboxes.append(box)
            views.append(box)
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
                    // "null" means unset, which for all of these means the default: on.
                    let isOn = value == "null" ? (toggle.on != "0") : (value != toggle.off)
                    self.checkboxes[index].state = isOn ? .on : .off
                }
            }
        }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let serial, sender.tag < Self.toggles.count else { return }
        let toggle = Self.toggles[sender.tag]
        let value = sender.state == .on ? toggle.on : toggle.off
        status.stringValue = "\(toggle.label) → \(value)"
        DispatchQueue.global(qos: .utility).async {
            _ = try? Adb.shell(serial, "settings put \(toggle.namespace) \(toggle.key) \(value)")
        }
    }
}
