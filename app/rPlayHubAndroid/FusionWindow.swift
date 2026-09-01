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
    /// The window was closed, by the user or programmatically. Fires once.
    var onClose: (() -> Void)?

    private let titlebar: FusionTitlebar
    private var hoverTimer: Timer?
    private var chromeShown = true       // forced through the first setChrome(false)
    /// The reveal only arms once the pointer has left the top band: opening from a menu leaves
    /// it right where the band is, which would flip the window out of raw mode as it appears.
    private var hoverArmed = false
    private var closed = false

    init(displayId: Int32, title: String, decorated: Bool,
         onWake: @escaping () -> Void, onScreenshot: @escaping () -> Void,
         onRecord: @escaping () -> Void) {
        self.displayId = displayId
        self.decorated = decorated
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1152, height: 648),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        window = w
        titlebar = FusionTitlebar(onWake: onWake, onScreenshot: onScreenshot, onRecord: onRecord)
        super.init()
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
        w.contentView = mirror
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
        let top = w.frame.maxY, left = w.frame.minX
        if visible { w.styleMask.remove(.fullSizeContentView) }
        else { w.styleMask.insert(.fullSizeContentView) }
        w.titlebarAppearsTransparent = !visible
        w.titleVisibility = visible ? .visible : .hidden
        for b in lights { b?.isHidden = !visible }
        titlebar.view.isHidden = !visible
        // Keep the picture where it was: anchor the frame at its top-left across the toggle.
        var f = w.frame
        f.origin = NSPoint(x: left, y: top - f.height)
        w.setFrame(f, display: true)

        let changed = visible != chromeShown
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
        let mouse = NSEvent.mouseLocation
        let f = w.frame
        let inX = mouse.x >= f.minX - 4 && mouse.x <= f.maxX + 4
        let band: CGFloat = chromeShown ? 90 : 64
        let near = inX && mouse.y <= f.maxY + 8 && mouse.y >= f.maxY - band
        guard hoverArmed else {
            if !near { hoverArmed = true }
            return
        }
        setChrome(visible: near)
    }
}
