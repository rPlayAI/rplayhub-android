//
//  FusionWindow.swift
//  A virtual display in its own window.
//
//  Fusion (an app on a virtual display) and Desktop Mode get a window of their own, with its own
//  MirrorView watching that display's stream — the phone's mirror in the main window (or its
//  pop-out) carries on untouched. It opens naked: the picture edge to edge under a transparent
//  title bar, nothing drawn around it; the chrome — traffic lights, title, and the Wake /
//  Screenshot / Record accessory — fades in when the pointer nears the top edge.
//

import AppKit

final class FusionWindow: NSObject, NSWindowDelegate {
    let displayId: Int32
    /// Desktop Mode's display (taskbar, launcher) rather than an app's bare one.
    let decorated: Bool
    let mirror = MirrorView()
    let window: NSWindow
    /// The app on this display, if it is an app's window rather than a desktop.
    var package: String?
    /// Host-side recorder for this display (Android's screenrecord can't capture a virtual
    /// display). Fed the decoded frames while active.
    let recorder = FrameRecorder()
    /// The window was closed, by the user or programmatically. Fires once.
    var onClose: (() -> Void)?
    /// The title bar's Record button. Set after init because the handler needs the window.
    var onRecord: (() -> Void)?

    private let titlebar: FusionTitlebar
    private var hoverTimer: Timer?
    private weak var tray: ReceivedTray?
    private var chromeShown = true       // forced through the first setChrome(false)
    /// The picture's top pad: the title bar's height while the chrome is shown, else zero.
    private var mirrorTop: NSLayoutConstraint?
    private var dragging = false
    private var settleUntil = Date.distantPast
    /// The reveal only arms once the pointer has left the top band: opening from a menu leaves
    /// it right where the band is, which would flip the window out of raw mode as it appears.
    private var hoverArmed = false
    private var closed = false

    init(displayId: Int32, title: String, decorated: Bool,
         onWake: @escaping () -> Void, onScreenshot: @escaping () -> Void) {
        self.displayId = displayId
        self.decorated = decorated
        // fullSizeContentView stays on in BOTH modes: the title bar is painted over the top of
        // the content when shown and the picture is padded down by its height, so the window
        // grows upward around a picture that never moves (see setChrome).
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1152, height: 648),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        window = w
        var recordTap: (() -> Void)?
        titlebar = FusionTitlebar(onWake: onWake, onScreenshot: onScreenshot,
                                  onRecord: { recordTap?() })
        super.init()
        recordTap = { [weak self] in self?.onRecord?() }
        w.title = title
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.tabbingMode = .disallowed
        // Transparent window: whatever isn't the picture simply isn't drawn.
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        mirror.borderless = true          // raw picture, no device bezel
        mirror.nakedBackground = true
        mirror.displayId = displayId
        // The picture inside a container, so a top pad can make room for the title bar.
        let container = NSView()
        mirror.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mirror)
        mirrorTop = mirror.topAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([
            mirrorTop!,
            mirror.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mirror.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mirror.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        w.contentView = container
        w.addTitlebarAccessoryViewController(titlebar)
        titlebar.position = w.titlebarAccessoryViewControllers.count - 1
        w.center()
        setChrome(visible: false, animated: false)
        w.makeKeyAndOrderFront(nil)
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.updateHover() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    var title: String {
        get { window.title }
        set { window.title = newValue }
    }

    func setRecording(_ on: Bool) { titlebar.setRecording(on) }

    func close() {
        guard !closed else { return }
        window.close()                    // windowWillClose does the rest
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        hoverTimer?.invalidate()
        hoverTimer = nil
        window.delegate = nil
        onClose?()
        onClose = nil
    }

    /// Files shared from the phone landed: show them as draggable thumbnails over this window's
    /// bottom-leading corner, so a photo shared from the fused app can be dragged straight out.
    func showReceived(_ urls: [URL]) {
        guard !urls.isEmpty, let content = window.contentView else { return }
        let tray: ReceivedTray
        if let existing = self.tray, existing.superview != nil {
            tray = existing
        } else {
            tray = ReceivedTray(frame: .zero)
            tray.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(tray)
            NSLayoutConstraint.activate([
                tray.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                tray.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ])
            self.tray = tray
        }
        tray.present(urls)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - chrome

    /// Toggle between raw (fullSizeContentView, transparent bar, no buttons — the picture fills
    /// everything) and the ordinary window (a real title bar above the picture, so the frame
    /// grows by its height rather than eating into the picture). Re-enforced on every hover tick
    /// because macOS restores chrome on activation.
    private func setChrome(visible: Bool, animated: Bool = true) {
        let w = window
        let lights = [w.standardWindowButton(.closeButton),
                      w.standardWindowButton(.miniaturizeButton),
                      w.standardWindowButton(.zoomButton)]
        w.titlebarAppearsTransparent = !visible
        w.titleVisibility = visible ? .visible : .hidden
        for b in lights { b?.isHidden = !visible }
        titlebar.view.isHidden = !visible
        let changed = visible != chromeShown
        if changed, let content = w.contentView {
            // Keep the PICTURE exactly where it is on screen: the title bar (and its accessory)
            // overlay the content, so pad the picture down by their height and grow the frame
            // upward by the same amount, both in one pass. Flipping the style mask instead
            // pushed the content down first and the frame after — the shake.
            let picture = w.convertToScreen(mirror.convert(mirror.framedPictureRect, to: nil)).integral
            let titleBar = visible ? content.bounds.height - w.contentLayoutRect.height : 0
            if picture.width > 0, picture.height > 0 {
                mirrorTop?.constant = titleBar
                w.setFrame(NSRect(x: picture.minX, y: picture.minY,
                                  width: picture.width, height: picture.height + titleBar),
                           display: false)
                content.layoutSubtreeIfNeeded()
                w.displayIfNeeded()
            }
        }

        chromeShown = visible
        guard changed, animated else { return }
        let a: CGFloat = visible ? 1 : 0
        for b in lights { b?.alphaValue = visible ? 0 : 1 }
        titlebar.view.alphaValue = visible ? 0 : 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            for b in lights { b?.animator().alphaValue = a }
            self.titlebar.view.animator().alphaValue = a
        }
    }

    /// Poll the cursor: a timer, not a mouse-moved monitor, so it works while the window isn't
    /// key. Hysteresis keeps a revealed traffic light from vanishing under the pointer.
    private func updateHover() {
        let w = window
        guard w.isVisible else { return }
        guard NSEvent.pressedMouseButtons == 0 else { dragging = true; return }   // never mid-drag
        if dragging { dragging = false; settleUntil = Date().addingTimeInterval(0.4) }
        let mouse = NSEvent.mouseLocation
        let f = w.frame
        let inX = mouse.x >= f.minX - 4 && mouse.x <= f.maxX + 4
        let band: CGFloat = chromeShown ? 90 : 64
        let near = inX && mouse.y <= f.maxY + 8 && mouse.y >= f.maxY - band
        guard hoverArmed else {
            if !near { hoverArmed = true }
            return
        }
        if !near, Date() < settleUntil { return }
        setChrome(visible: near)
    }
}
