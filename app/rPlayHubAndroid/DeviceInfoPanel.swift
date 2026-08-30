//
//  DeviceInfoPanel.swift
//  The Info sub-tab: what the device says about itself, and how the stream is doing.
//
//  Properties are read once per device rather than on a timer — they cannot change while it is
//  plugged in, and each one is a round trip. Stream health is pushed in by AppDelegate.
//

import AppKit

final class DeviceInfoPanel: NSView {
    var serial: String? {
        didSet {
            guard serial != oldValue else { return }
            propertiesLabel.stringValue = serial == nil ? "No device selected" : "Loading…"
            healthLabel.stringValue = ""
            if serial != nil { loadProperties() }
        }
    }

    private let propertiesLabel = NSTextField(labelWithString: "No device selected")
    private let healthLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        func header(_ title: String) -> NSTextField {
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }
        for label in [propertiesLabel, healthLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 24
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        healthLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header("Device"), propertiesLabel,
                                        header("Stream"), healthLabel])
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
        // Activated only now: until the stack is installed these labels and `self` share no
        // common ancestor, and a constraint across that gap throws at launch.
        for label in [propertiesLabel, healthLabel] {
            label.widthAnchor.constraint(equalTo: widthAnchor, constant: -28).isActive = true
        }
    }

    func setHealth(_ text: String) { healthLabel.stringValue = text }

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
            var lines = ["Serial   \(serial)"]
            for (index, entry) in wanted.enumerated() where index < values.count {
                lines.append(entry.0.padding(toLength: 9, withPad: " ", startingAt: 0)
                             + values[index])
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.serial == serial else { return }
                self.propertiesLabel.stringValue = text
            }
        }
    }
}
