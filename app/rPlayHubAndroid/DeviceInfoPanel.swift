//
//  DeviceInfoPanel.swift
//  The Info sub-tab: what the device says about itself, and how the stream is doing.
//
//  Properties are read once per device rather than on a timer — they cannot change while it is
//  plugged in, and each one is a round trip. Stream health is pushed in by AppDelegate.
//
//  Laid out as name/value rows — the name column bold on the left, values beside it — matching
//  how Device Hub sets its info panes, rather than one monospaced block.
//

import AppKit

final class DeviceInfoPanel: NSView {
    var serial: String? {
        didSet {
            guard serial != oldValue else { return }
            healthLabel.stringValue = ""
            if serial == nil {
                setStatus("No device selected")
            } else {
                setStatus("Loading…")
                loadProperties()
            }
        }
    }

    /// The Device section's rows are rebuilt here whenever properties arrive.
    private let rows = NSStackView()
    private let healthLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func header(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func build() {
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5

        healthLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        healthLabel.textColor = .secondaryLabelColor
        healthLabel.lineBreakMode = .byWordWrapping
        healthLabel.maximumNumberOfLines = 12
        healthLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        setStatus("No device selected")

        let stack = NSStackView(views: [header("Device"), rows, header("Stream"), healthLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        healthLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
        // Now in the hierarchy: give the rows column the panel width so values wrap within it.
        rows.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
    }

    func setHealth(_ text: String) { healthLabel.stringValue = text }

    // MARK: - rows

    /// One "Name  value" line: the name bold in a fixed-width left column, the value regular and
    /// free to wrap. Fonts and colours follow Device Hub — bold label, muted value.
    private func makeRow(name: String, value: String) -> NSView {
        let n = NSTextField(labelWithString: name)
        n.font = .systemFont(ofSize: 11, weight: .bold)
        n.textColor = .labelColor
        n.setContentHuggingPriority(.required, for: .horizontal)
        n.setContentCompressionResistancePriority(.required, for: .horizontal)
        n.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 11, weight: .regular)
        v.textColor = .secondaryLabelColor
        v.lineBreakMode = .byCharWrapping
        v.maximumNumberOfLines = 3
        v.isSelectable = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [n, v])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func setStatus(_ text: String) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        rows.addArrangedSubview(l)
    }

    private func setRows(_ pairs: [(String, String)]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (name, value) in pairs {
            let row = makeRow(name: name, value: value)
            rows.addArrangedSubview(row)
            // Safe to pin now — the row shares `rows` as an ancestor. Full width so values wrap.
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    private func loadProperties() {
        guard let serial else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let wanted = [("Model", "ro.product.model"), ("Device", "ro.product.device"),
                          ("Android", "ro.build.version.release"), ("SDK", "ro.build.version.sdk"),
                          ("ABI", "ro.product.cpu.abi"), ("Build", "ro.build.display.id")]
            // One round trip, not six — over wifi adb each is ~60ms.
            let query = wanted.map { "getprop \($0.1)" }.joined(separator: "; ")
            let values = ((try? Adb.shell(serial, query)) ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var pairs = [("Serial", serial)]
            for (index, entry) in wanted.enumerated() where index < values.count {
                pairs.append((entry.0, values[index]))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.serial == serial else { return }
                self.setRows(pairs)
            }
        }
    }
}
