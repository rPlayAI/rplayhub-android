//
//  EmulatorSetup.swift
//  "Create Android VM…" — the whole path from a Mac with nothing installed to a booted emulator.
//
//  This is the reason rPlayHub exists: an Android VM without Android Studio, without a JDK, and
//  without the user ever meeting sdkmanager. The pieces come from Google's own repository on
//  demand (SdkCatalog/SdkInstaller), Google's licence is shown and recorded, and the AVD is
//  written directly (AvdCreator). We redistribute nothing and need no admin rights.
//

import AppKit

@MainActor
final class EmulatorSetup {
    /// The VM is ready to launch. Handed the AVD so the caller can start and host it.
    var onReady: ((Avd) -> Void)?

    private weak var window: NSWindow?
    private var panel: NSWindow?
    private var status = NSTextField(labelWithString: "")
    private var detail = NSTextField(labelWithString: "")
    private var bar = NSProgressIndicator()
    private var task: Task<Void, Never>?

    init(window: NSWindow?) { self.window = window }

    // MARK: - the flow

    /// Fetch the catalog, ask what to build, install what is missing, create the AVD.
    func start() {
        showProgress(title: "Contacting Google's SDK repository…", indeterminate: true)
        task = Task {
            do {
                let index = try await SdkCatalog.fetchAll()
                guard !Task.isCancelled else { return }
                hideProgress()
                guard let choice = await ask(with: index) else { return }
                try await install(choice, from: index)
            } catch is CancellationError {
                hideProgress()
            } catch {
                hideProgress()
                AppBuild.log("emulator setup failed: \(error)")
                present("Could not set up the emulator", "\(error)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        hideProgress()
    }

    private struct Choice {
        let image: SdkPackage
        let profile: DeviceProfile
        let name: String
        let emulator: SdkPackage?      // nil when a usable emulator is already installed
    }

    /// One sheet: Android version, device, name — and what it will cost to download.
    private func ask(with index: SdkCatalog.Index) async -> Choice? {
        let images = SdkCatalog.systemImages(in: index)
        guard !images.isEmpty else {
            present("No system images available",
                    "Google's index has no arm64 system image this Mac can run.")
            return nil
        }
        let root = SdkInstaller.installRoot
        let emulatorPackage = SdkCatalog.emulator(in: index)
        // Upgrade an emulator that is older than what Google publishes, not just install a
        // missing one: an older emulator silently fails to boot a newer system image.
        let installedRevision = SdkCatalog.installedEmulatorRevision(root: root)
            ?? AndroidSdk.root.flatMap { SdkCatalog.installedEmulatorRevision(root: $0) }
        let needsEmulator: Bool = {
            guard AndroidSdk.emulatorBinary != nil, let have = installedRevision,
                  let want = emulatorPackage?.revision else { return true }
            return have.compare(want, options: .numeric) == .orderedAscending
        }()

        let alert = NSAlert()
        alert.messageText = "Create an Android VM"
        alert.informativeText = "rPlayHub downloads the Android emulator and a system image from "
            + "Google and creates the virtual device. No Android Studio and no JDK are needed."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let versions = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        for image in images {
            let api = image.apiLabel.map { "Android API \($0)" } ?? image.path
            let store = (image.tag ?? "").contains("playstore") ? "Play Store" : "Google APIs (rootable)"
            let gb = Double(image.size) / 1_073_741_824
            versions.addItem(withTitle: String(format: "%@ · %@ · %.1f GB", api, store, gb))
        }
        // Default to a rootable image that is known to boot, not simply the newest — see
        // SdkCatalog.defaultImageIndex. adb root is what a tool like this is for.
        versions.selectItem(at: SdkCatalog.defaultImageIndex(in: images))

        let devices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        for profile in DeviceProfile.all { devices.addItem(withTitle: profile.name) }

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.stringValue = AvdCreator.availableName(basedOn: "Android_VM")
        // A stack view sizes its children by their intrinsic width, and a text field's is its
        // content — so the frame above is ignored and the field comes out far too narrow to
        // read a VM name in. Pin all three controls to the same width instead.
        let fieldWidth: CGFloat = 320
        for control in [versions as NSView, devices as NSView, nameField as NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        }

        func row(_ label: String, _ view: NSView) -> NSView {
            let caption = NSTextField(labelWithString: label)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [caption, view])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            return stack
        }
        let note = NSTextField(labelWithString: needsEmulator
            ? (installedRevision == nil
                ? "The Android emulator (about 400 MB) will be downloaded too."
                : "The Android emulator will be updated (about 400 MB) — \(installedRevision ?? "") "
                  + "cannot boot the newest system images.")
            : "The Android emulator is already installed.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [row("Android version", versions),
                                        row("Device", devices),
                                        row("Name", nameField), note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: fieldWidth + 10, height: 190)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window {
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                continuation.resume(returning: alert.runModal())
            }
        }
        guard response == .alertFirstButtonReturn else { return nil }

        let image = images[max(0, versions.indexOfSelectedItem)]
        let profile = DeviceProfile.all[max(0, devices.indexOfSelectedItem)]
        let name = AvdCreator.availableName(basedOn: nameField.stringValue)
        return Choice(image: image, profile: profile, name: name,
                      emulator: needsEmulator ? emulatorPackage : nil)
    }

    /// Download what is missing, then write the AVD.
    private func install(_ choice: Choice, from index: SdkCatalog.Index) async throws {
        let installer = SdkInstaller()
        let root = SdkInstaller.installRoot
        let licence = choice.image.licenseId.flatMap { index.licenses[$0] }

        showProgress(title: "Preparing…", indeterminate: true)

        if let emulator = choice.emulator {
            status.stringValue = "Downloading the Android emulator…"
            try await installer.install(emulator, into: root,
                                        license: emulator.licenseId.flatMap { index.licenses[$0] }) { phase in
                Task { @MainActor in self.report(phase, of: emulator.size) }
            }
            // The emulator we just installed is the one to use from now on.
            UserDefaults.standard.set(root.path, forKey: AndroidSdk.rootDefaultsKey)
            AppBuild.log("sdk: emulator now \(emulator.revision) at \(root.path)")
        }
        guard !Task.isCancelled else { hideProgress(); return }

        if !SdkInstaller.isInstalled(choice.image, root: root) {
            status.stringValue = "Downloading Android \(choice.image.apiLabel ?? "")…"
            try await installer.install(choice.image, into: root, license: licence) { phase in
                Task { @MainActor in self.report(phase, of: choice.image.size) }
            }
        }
        guard !Task.isCancelled else { hideProgress(); return }
        UserDefaults.standard.set(root.path, forKey: AndroidSdk.rootDefaultsKey)

        status.stringValue = "Creating \(choice.name)…"
        detail.stringValue = ""
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let avd = try AvdCreator.create(name: choice.name, imagePath: choice.image.path,
                                        profile: choice.profile, sdkRoot: root)
        hideProgress()
        AppBuild.log("emulator setup: \(choice.name) ready (\(choice.image.path))")
        onReady?(avd)
    }

    // MARK: - progress

    private func report(_ phase: SdkInstaller.Phase, of total: Int64) {
        switch phase {
        case .waiting:
            bar.isIndeterminate = true; bar.startAnimation(nil)
            detail.stringValue = "Connecting…"
        case .downloading(let received, let expected):
            let cap = expected > 0 ? expected : total
            bar.isIndeterminate = false
            bar.doubleValue = cap > 0 ? Double(received) / Double(cap) * 100 : 0
            detail.stringValue = "\(Self.bytes(received)) of \(Self.bytes(cap))"
        case .verifying:
            bar.isIndeterminate = true; bar.startAnimation(nil)
            detail.stringValue = "Verifying the download…"
        case .installing:
            bar.isIndeterminate = true; bar.startAnimation(nil)
            detail.stringValue = "Unpacking…"
        case .done:
            detail.stringValue = ""
        }
    }

    private static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    private func showProgress(title: String, indeterminate: Bool) {
        status.stringValue = title
        detail.stringValue = ""
        bar.isIndeterminate = indeterminate
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        if indeterminate { bar.startAnimation(nil) }
        guard panel == nil else { return }

        status.font = .systemFont(ofSize: 13, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded

        let buttons = NSStackView(views: [NSView(), cancel])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [status, bar, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Android VM"
        w.contentView = stack
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 380),
            buttons.widthAnchor.constraint(equalToConstant: 380),
        ])
        w.center()
        panel = w
        if let window {
            window.beginSheet(w) { _ in }
        } else {
            w.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func cancelTapped() { cancel() }

    private func hideProgress() {
        bar.stopAnimation(nil)
        guard let panel else { return }
        if let window { window.endSheet(panel) } else { panel.orderOut(nil) }
        self.panel = nil
    }

    private func present(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
