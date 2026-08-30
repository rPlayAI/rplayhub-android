//
//  LogcatWindow.swift
//  The log in a window of its own, alongside ScreenWindow's "Open in New Window".
//
//  Unlike ScreenWindow this does NOT move the existing view out of the inspector. The screen has
//  to move because two views cannot share one AVSampleBufferDisplayLayer; the log has no such
//  constraint, and reparenting a panel out of the inspector's tab container would leave a hole
//  that container has no concept of. A second LogcatPanel is cheap.
//
//  What is not cheap is a second logcat socket, so the inline panel is suppressed for as long as
//  this window is up: one stream, in the place the user is actually looking.
//

import AppKit

final class LogcatWindow {
    private(set) var window: NSWindow?
    private var panel: LogcatPanel?
    private var observer: NSObjectProtocol?

    /// Called after the window closes, so the inspector can resume its inline panel.
    var onClose: (() -> Void)?

    var isOpen: Bool { window != nil }

    func open(serial: String?, title: String, tabbedWith sibling: NSWindow?) {
        if let window {                                  // already out — just show it
            window.makeKeyAndOrderFront(nil)
            return
        }

        let p = LogcatPanel()
        p.isDetached = true                              // set before the view builds its bar
        p.translatesAutoresizingMaskIntoConstraints = false
        panel = p

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentView = p
        w.setFrameAutosaveName("LogcatWindow")
        w.tabbingMode = sibling != nil ? .preferred : .disallowed
        w.isReleasedWhenClosed = false
        window = w

        if let sibling {
            sibling.addTabbedWindow(w, ordered: .above)
        }
        w.makeKeyAndOrderFront(nil)

        // Assigning serial is what starts the stream, so it goes last — after the view is in a
        // window and visible, or `isHidden` would stop it again immediately.
        p.serial = serial

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                self?.teardown()
            }
    }

    /// Follow the inspector's device selection while detached.
    func update(serial: String?) { panel?.serial = serial }

    func close() { window?.close() }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel?.serial = nil                              // closes the logcat socket
        panel = nil
        window = nil
        onClose?()
    }
}
