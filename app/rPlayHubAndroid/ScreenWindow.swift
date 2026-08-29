//
//  ScreenWindow.swift
//  The live screen in a window of its own — Device Hub's "Open in New Tab" / "Open in New Window".
//
//  There is one live stream and one MirrorView, so this moves that view rather than creating a
//  second one. Two views cannot share an AVSampleBufferDisplayLayer, and decoding the stream twice
//  to feed a copy would double the cost of the one thing in this app that is expensive.
//
//  Moving it means the split view is left with a hole, so a placeholder takes its place and says
//  where the screen went. Closing the window puts the view back exactly where it was.
//

import AppKit

final class ScreenWindow {
    private(set) var window: NSWindow?
    private weak var host: NSSplitView?
    private weak var screen: NSView?
    private var placeholder: NSView?
    private var index: Int = 1
    private var observer: NSObjectProtocol?

    /// Called after the window closes and the screen has been put back.
    var onClose: (() -> Void)?

    var isOpen: Bool { window != nil }

    /// Detach `stage` (the screen and its action strip) out of `host` and into a window.
    /// `sibling` is the window to tab with; pass nil for a standalone window.
    func open(stage: NSView, from host: NSSplitView, title: String, tabbedWith sibling: NSWindow?) {
        if let window {                                  // already out — just show it
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let position = host.arrangedSubviews.firstIndex(of: stage) else { return }
        self.host = host
        self.screen = stage
        self.index = position

        let stand = NSView()
        stand.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Screen is in its own window")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        stand.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: stand.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: stand.centerYAnchor),
        ])
        placeholder = stand

        let size = stage.frame.size
        host.removeArrangedSubview(stage)
        stage.removeFromSuperview()
        host.insertArrangedSubview(stand, at: position)

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentView = stage
        w.setFrameAutosaveName("ScreenWindow")
        // Let AppKit manage tabbing; .preferred is what makes addTabbedWindow group rather than
        // open a second free-floating window.
        w.tabbingMode = sibling != nil ? .preferred : .disallowed
        w.isReleasedWhenClosed = false
        window = w

        if let sibling {
            sibling.addTabbedWindow(w, ordered: .above)
        }
        w.makeKeyAndOrderFront(nil)

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.reattach()
            }
    }

    /// Put the screen back in the split view. Safe to call when nothing is detached.
    func reattach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let host, let screen, let placeholder else { window = nil; return }

        screen.removeFromSuperview()
        host.removeArrangedSubview(placeholder)
        placeholder.removeFromSuperview()
        host.insertArrangedSubview(screen, at: min(index, host.arrangedSubviews.count))

        self.placeholder = nil
        self.screen = nil
        self.host = nil
        window = nil
        onClose?()
    }
}
