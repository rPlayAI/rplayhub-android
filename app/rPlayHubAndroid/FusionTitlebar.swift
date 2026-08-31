//
//  FusionTitlebar.swift
//  Title-bar controls for a chromeless fusion window — the actions a fused app on a virtual
//  display still needs when the main control strip is hidden: Wake, Screenshot, and Record.
//  Lives on the trailing side of the window's title bar as an accessory view controller.
//

import AppKit

final class FusionTitlebar: NSTitlebarAccessoryViewController {
    private let onWake: () -> Void
    private let onScreenshot: () -> Void
    private let onRecord: () -> Void

    /// The index this accessory sits at in the window's accessory list, for later removal.
    var position = 0

    private let recordButton = NSButton()

    init(onWake: @escaping () -> Void,
         onScreenshot: @escaping () -> Void,
         onRecord: @escaping () -> Void) {
        self.onWake = onWake
        self.onScreenshot = onScreenshot
        self.onRecord = onRecord
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let wake = button("moon.zzz", "Wake the device", #selector(wakeTapped))
        let shot = button("camera", "Screenshot this display", #selector(shotTapped))
        configure(recordButton, symbol: "record.circle", tip: "Record this display",
                  action: #selector(recordTapped))

        let stack = NSStackView(views: [wake, shot, recordButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A title-bar accessory collapses to nothing unless its view has a real size, so host the
        // buttons in a fixed-size container and pin the stack inside it.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 96),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    /// Flip the record button to show it's live (filled red) or idle.
    func setRecording(_ on: Bool) {
        recordButton.contentTintColor = on ? .systemRed : nil
        recordButton.image = symbolImage(on ? "stop.circle" : "record.circle")
        recordButton.toolTip = on ? "Stop recording" : "Record this display"
    }

    // MARK: - button helpers

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        configure(b, symbol: symbol, tip: tip, action: action)
        return b
    }

    private func configure(_ b: NSButton, symbol: String, tip: String, action: Selector) {
        b.image = symbolImage(symbol)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.toolTip = tip
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    @objc private func wakeTapped() { onWake() }
    @objc private func shotTapped() { onScreenshot() }
    @objc private func recordTapped() { onRecord() }
}
