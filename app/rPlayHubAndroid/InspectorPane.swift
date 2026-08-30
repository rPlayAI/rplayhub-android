//
//  InspectorPane.swift
//  The right-hand pane and its tabs.
//
//  Two levels, the shape ~/rplay-hub took from Device Hub: a row of 3 ICON tabs that lives in the
//  window's TITLE BAR at the trailing edge — same row as the traffic lights, not in the content
//  area — and under each, a row of text-named sub-tabs.
//
//      Settings   device switches worth having beside a mirror
//      Logs       Logcat | Crashes
//      Info       Info | Apps | Files
//
//  `iconTabs` is built here because it drives this pane's selection, but AppDelegate lifts it
//  into a title-bar accessory rather than adding it as a subview.
//
//  Re-clicking the active icon collapses the pane, as Device Hub does.
//

import AppKit

final class InspectorPane: NSView {
    let info = DeviceInfoPanel()
    let apps = AppsPanel()
    let files = FilesPanel()
    let logcat = LogcatPanel()
    let crashes = CrashesPanel()
    let settings = SettingsPanel()

    /// Lives in the title bar, not in this view — exposed so AppDelegate can put it there.
    /// Hand-rolled (see IconTabBar) because a segmented control paints its selection with the
    /// accent colour and Device Hub's is grey.
    let iconTabs = IconTabBar(icons: [("slider.horizontal.3", "Settings"),
                                      ("doc.text", "Logs"),
                                      ("info", "Info")])

    /// Called when the pane collapses or reappears, so the window can react.
    var onVisibilityChanged: ((Bool) -> Void)?

    var serial: String? {
        didSet {
            info.serial = serial
            apps.serial = serial
            files.serial = serial
            logcat.serial = serial
            crashes.serial = serial
            settings.serial = serial
            logcatWindow.update(serial: serial)
        }
    }

    /// The log detached into a window of its own. While it is up the inline panel is suppressed,
    /// so only one logcat socket is ever open.
    let logcatWindow = LogcatWindow()

    private let textTabs = NSSegmentedControl()
    private let container = NSView()

    private static let settingsIcon = 0, logsIcon = 1, infoIcon = 2
    private var activeIcon = infoIcon
    /// Remembered per icon tab, so switching away and back returns to the same sub-tab.
    private var activeText: [Int: Int] = [:]

    /// The sub-tabs under each icon tab, in order.
    private var subTabs: [Int: [(String, NSView)]] {
        [Self.settingsIcon: [("Settings", settings)],
         Self.logsIcon:     [("Logcat", logcat), ("Crashes", crashes)],
         Self.infoIcon:     [("Info", info), ("Apps", apps), ("Files", files)]]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func wireLogcatPopOut() {
        logcat.onPopOut = { [weak self] in
            guard let self else { return }
            self.logcat.setSuppressed(true)
            self.logcatWindow.onClose = { [weak self] in self?.logcat.setSuppressed(false) }
            self.logcatWindow.open(serial: self.serial,
                                   title: "Logcat", tabbedWith: self.window)
        }
    }

    private func build() {
        // Same pane colour as ~/rplay-hub's inspector.
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255,
                                         blue: 0xFA / 255, alpha: 1).cgColor
        iconTabs.selected = activeIcon
        iconTabs.onSelect = { [weak self] index in self?.iconSelected(index) }

        textTabs.segmentStyle = .automatic
        textTabs.trackingMode = .selectOne
        textTabs.segmentDistribution = .fillEqually
        textTabs.target = self
        textTabs.action = #selector(textTabChanged)
        textTabs.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        for panel in [info as NSView, apps, files, logcat, crashes, settings] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.isHidden = true
            container.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: container.topAnchor),
                panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        addSubview(textTabs)
        addSubview(container)
        NSLayoutConstraint.activate([
            textTabs.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textTabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textTabs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            container.topAnchor.constraint(equalTo: textTabs.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        showIcon(activeIcon)
        wireLogcatPopOut()
    }

    // MARK: - tabs

    private func iconSelected(_ index: Int) {
        // Re-selecting the active tab collapses the pane, as Device Hub does.
        if index == activeIcon, !isHidden {
            isHidden = true
            iconTabs.selected = nil
            onVisibilityChanged?(false)
            return
        }
        if isHidden {
            isHidden = false
            onVisibilityChanged?(true)
        }
        showIcon(index)
    }

    private func showIcon(_ index: Int) {
        activeIcon = index
        iconTabs.selected = index
        let tabs = subTabs[index] ?? []

        textTabs.segmentCount = tabs.count
        for (i, tab) in tabs.enumerated() {
            textTabs.setLabel(tab.0, forSegment: i)
            textTabs.setWidth(0, forSegment: i)      // even split, see segmentDistribution
        }
        // A single sub-tab is not a choice; hide the row rather than showing one lonely segment.
        textTabs.isHidden = tabs.count < 2

        let wanted = min(activeText[index] ?? 0, max(tabs.count - 1, 0))
        textTabs.selectedSegment = wanted
        showPanel(tabs, wanted)
    }

    @objc private func textTabChanged() {
        let tabs = subTabs[activeIcon] ?? []
        let index = max(0, textTabs.selectedSegment)
        activeText[activeIcon] = index
        showPanel(tabs, index)
    }

    private func showPanel(_ tabs: [(String, NSView)], _ index: Int) {
        for (i, tab) in tabs.enumerated() { tab.1.isHidden = i != index }
        // Panels not under the current icon tab stay hidden — which is also what stops the
        // logcat stream when it is not being looked at.
        let visible = tabs.indices.contains(index) ? tabs[index].1 : nil
        for panel in [info as NSView, apps, files, logcat, crashes, settings]
        where !tabs.contains(where: { $0.1 === panel }) {
            panel.isHidden = true
        }
        _ = visible
    }

    /// Bring the pane back if it was collapsed, showing a particular icon tab.
    func reveal(icon: Int) {
        if isHidden {
            isHidden = false
            onVisibilityChanged?(true)
        }
        showIcon(icon)
    }
}
