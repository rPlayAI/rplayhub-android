//
//  FinderMount.swift
//  The phone in Finder: one File Provider domain per ready device.
//
//  The extension (app/FinderMount/) does the listing and pulling; this side only tells the
//  system which devices exist. A domain is registered when a device is ready and removed when
//  it goes away or the app quits — the mount is live exactly while the phone is, and Finder
//  never shows a phone that cannot answer. Registration is keyed by the adb serial, which is the
//  domain identifier the extension gets handed and all it needs.
//
//  Trap: NSFileProviderManager only works when the process was launched through LaunchServices
//  (`open`, Finder, Dock). Run the binary straight from a shell and every call fails with
//  -2001 "cannot be used right now" — fileproviderd cannot find the extension of a process it
//  does not know as an app.
//

import AppKit
import FileProvider

enum FinderMount {
    private static var mounted: [String: NSFileProviderDomain] = [:]
    private static var pending: Set<String> = []
    /// Serials whose registration failed. Not retried until the device has gone away and come
    /// back — a hard failure repeats identically on every 2-second poll otherwise.
    private static var failed: Set<String> = []

    /// One-shot: drop EVERY domain this app's provider owns. For the developer reset switch
    /// (RPLAYHUB_RESET_MOUNTS) — e.g. after a bundle-id change leaves an orphaned domain behind.
    static func resetAllDomains(completion: @escaping () -> Void) {
        NSFileProviderManager.removeAllDomains { error in
            if let error { AppBuild.log("finder mount: reset failed: \(error)") }
            else { AppBuild.log("finder mount: all domains reset") }
            DispatchQueue.main.async { mounted.removeAll(); completion() }
        }
    }

    /// Bring the registered domains in line with the ready devices. Cheap to call on every
    /// poll: nothing happens unless the set changed.
    static func sync(devices: [AdbDevice]) {
        let ready = Dictionary(uniqueKeysWithValues:
            devices.filter { $0.isReady }.map { ($0.serial, $0) })
        for serial in mounted.keys where ready[serial] == nil {
            remove(serial: serial)
        }
        failed = failed.filter { ready[$0] != nil }
        for (serial, device) in ready
        where mounted[serial] == nil && !pending.contains(serial) && !failed.contains(serial) {
            add(device)
        }
    }

    private static func add(_ device: AdbDevice) {
        let domain = NSFileProviderDomain(identifier: .init(AdbDevice.domainIdentifier(for: device.serial)),
                                          displayName: device.displayName)
        pending.insert(device.serial)
        NSFileProviderManager.add(domain) { error in
            DispatchQueue.main.async {
                pending.remove(device.serial)
                if let error {
                    failed.insert(device.serial)
                    AppBuild.log("finder mount: cannot add \(device.serial): \(error)")
                } else {
                    mounted[device.serial] = domain
                    AppBuild.log("finder mount: \(device.displayName) mounted")
                    checkEnabled(domain)
                }
            }
        }
    }

    private static func remove(serial: String) {
        guard let domain = mounted.removeValue(forKey: serial) else { return }
        // .removeAll: drop the system's cached listing too. Nothing in it is worth keeping —
        // it is a view of the phone, re-listed on the next mount — and a stale copy is how a
        // file the phone deleted stays visible.
        NSFileProviderManager.remove(domain, mode: .removeAll) { _, error in
            if let error { AppBuild.log("finder mount: cannot remove \(serial): \(error)") }
        }
    }

    /// On quit. Waits briefly so the removal is actually sent before the process is gone; a
    /// domain left behind would show a phone in Finder that nothing can answer for.
    static func removeAll() {
        guard !mounted.isEmpty else { return }
        let done = DispatchGroup()
        for domain in mounted.values {
            done.enter()
            NSFileProviderManager.remove(domain, mode: .removeAll) { _, _ in done.leave() }
        }
        _ = done.wait(timeout: .now() + 3)
        mounted.removeAll()
    }

    static func isMounted(_ serial: String) -> Bool { mounted[serial] != nil }

    // MARK: - the System Settings switch

    private static var askedToEnable = false

    /// macOS keeps a third-party File Provider switched OFF until the user turns it on in
    /// System Settings (General › Login Items & Extensions › File Providers). Until then the
    /// domain exists but every request fails with "sync is not enabled", which Finder shows as
    /// a location that never loads. `userEnabled` only reflects that switch on the domain the
    /// system hands back, so it has to be re-fetched after the add.
    private static func checkEnabled(_ added: NSFileProviderDomain) {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            guard let domain = domains.first(where: { $0.identifier == added.identifier }) else {
                return
            }
            AppBuild.log("finder mount: \(domain.displayName) userEnabled=\(domain.userEnabled)")
            guard !domain.userEnabled else { return }
            DispatchQueue.main.async { offerToEnable(domain.displayName) }
        }
    }

    /// Once per launch: the extension is off, and only the user can turn it on.
    private static func offerToEnable(_ deviceName: String) {
        guard !askedToEnable else { return }
        askedToEnable = true
        let alert = NSAlert()
        alert.messageText = "Turn on rPlayHub Android in System Settings to see \(deviceName) in Finder"
        alert.informativeText = "macOS keeps a new Finder location switched off until you allow it. "
            + "In System Settings, go to General › Login Items & Extensions, scroll to Extensions › "
            + "File Providers, and turn on rPlayHub Android. The phone's files then appear under "
            + "Locations in Finder, and Show Files in Finder opens them."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    static func openSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    /// Open the phone's folder in Finder.
    static func reveal(serial: String) {
        guard let domain = mounted[serial],
              let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { url, error in
            guard let url else {
                AppBuild.log("finder mount: no URL for \(serial): \(String(describing: error))")
                return
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }
}
