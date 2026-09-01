//
//  ReceivedTray.swift
//  "Drag it out" — items shared from the phone, made draggable on the fusion window.
//
//  Android won't let a drag that starts inside a mirrored app carry its file across to the Mac
//  (the content URI is delivered only on drop, never as the drag begins — a security rule). So
//  the flow is share-to-send: in the fused app you tap Share ▸ Send to Mac, the companion drops
//  the file in its outbox, the Mac pulls it (ShareInbox), and it appears HERE — a row of
//  thumbnails floating over the fusion window that you drag out natively, as real files. It sits
//  in the corner, dismisses itself after a while or when clicked away.
//

import AppKit

final class ReceivedTray: NSView {
    private let stack = NSStackView()
    private var dismissTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.82).cgColor
        layer?.cornerRadius = 12
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let caption = NSTextField(labelWithString: "Drag to your Mac")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .white
        caption.alignment = .center

        let close = NSButton(title: "✕", target: self, action: #selector(dismiss))
        close.isBordered = false
        close.contentTintColor = .white
        close.font = .systemFont(ofSize: 11, weight: .bold)
        close.setButtonType(.momentaryChange)

        let header = NSStackView(views: [caption, close])
        header.orientation = .horizontal
        header.distribution = .fill
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY

        let column = NSStackView(views: [header, stack])
        column.orientation = .vertical
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show these files (adds to whatever is already there — a second share stacks on). Keeps at
    /// most the eight most recent so the tray never outgrows the window.
    func present(_ urls: [URL]) {
        for url in urls {
            stack.addArrangedSubview(DraggableThumb(url: url))
        }
        while stack.arrangedSubviews.count > 8 {
            let extra = stack.arrangedSubviews[0]
            stack.removeArrangedSubview(extra)
            extra.removeFromSuperview()
        }
        armDismiss()
    }

    private func armDismiss() {
        dismissTimer?.invalidate()
        // Long enough to grab and drag; the user can also close it or it fades on the next share.
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    @objc private func dismiss() {
        dismissTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }
}

/// One thumbnail that drags out as its real file. NSURL is a pasteboard writer, so a drop into
/// Finder, Mail, a chat — anywhere that takes files — gets the actual file.
private final class DraggableThumb: NSImageView, NSDraggingSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 56).isActive = true
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.25).cgColor
        image = Self.thumbnail(for: url)
        toolTip = url.lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let dragImage = image ?? NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(bounds, contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// A picture gets a real thumbnail; anything else, its file-type icon.
    private static func thumbnail(for url: URL) -> NSImage {
        if let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
