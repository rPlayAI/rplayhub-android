//
//  InspectorPane.swift
//  The right pane: what the device says about itself, and how the stream is doing.
//
//  Properties come from getprop, once per selection rather than on a timer — they do not change
//  while a device is plugged in, and each one is a round trip through the adb server.
//

import AppKit

final class InspectorPane: NSView {
    private let stack = NSStackView()
    private let propertiesLabel = NSTextField(labelWithString: "")
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
            label.textColor = .labelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 20
        }
        healthLabel.textColor = .secondaryLabelColor

        stack.setViews([header("Device"), propertiesLabel,
                        header("Stream"), healthLabel], in: .top)
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

    func setProperties(_ text: String) { propertiesLabel.stringValue = text }
    func setHealth(_ text: String) { healthLabel.stringValue = text }
}
