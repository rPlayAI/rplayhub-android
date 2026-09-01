//
//  ShareInbox.swift
//  The Mac side of the companion app: shared items arriving from the phone.
//
//  The companion (helper/, package com.rplay.rplayhub.helper) is a Share-sheet target: from any
//  Android app you tap Share ▸ Send to Mac, and it copies the shared items into its own external
//  files "outbox" — /sdcard/Android/data/<pkg>/files/outbox/<batch>/ — writing a `.ready` marker
//  last. That directory needs no runtime permission on the phone and the adb shell can read it
//  (shell is in the ext_data_rw group), so no Shizuku and no companion-side network service are
//  needed: this simply polls the outbox over adb while a session is live, pulls each ready batch
//  to ~/Downloads/rPlayHub Shared/, deletes it on the device, and reveals it in Finder — where a
//  drag out is a native file drag.
//

import AppKit

final class ShareInbox {
    static let helperPackage = "com.rplay.rplayhub.helper"
    private static let outboxRemote =
        "/sdcard/Android/data/\(helperPackage)/files/outbox"

    /// Called on the main queue with the files just pulled from the phone.
    var onReceived: (([URL]) -> Void)?

    private var serial: String?
    private var timer: Timer?
    /// Batches being pulled right now, so a slow pull is not started again on the next tick.
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "rplayhub.share-inbox", qos: .utility)

    /// Where shared items land on the Mac. One folder, shown in Finder as they arrive.
    private lazy var destination: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = downloads.appendingPathComponent("rPlayHub Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Begin watching a device's outbox. Cheap to call again with the same serial (no-op).
    func start(serial: String) {
        if self.serial == serial, timer != nil { return }
        stop()
        self.serial = serial
        // A 2-second poll of one small directory: the same bounded `ls` the Finder mount runs, so
        // it does not risk the logcat-style hang the streaming path warns about.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        serial = nil
    }

    private func poll() {
        guard let serial else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // Ready batches, oldest first — the batch name is milliseconds-since-epoch, so a
            // lexical sort is chronological. A batch counts only once its `.ready` marker exists.
            guard let batches = try? Adb.list(serial, path: ShareInbox.outboxRemote) else { return }
            for batch in batches.sorted(by: { $0.name < $1.name }) where batch.isDirectory {
                // Claim the batch on the main actor so two ticks never pull it at once.
                let claimed = DispatchQueue.main.sync { () -> Bool in
                    guard !self.inFlight.contains(batch.name) else { return false }
                    self.inFlight.insert(batch.name)
                    return true
                }
                guard claimed else { continue }
                self.pullBatch(serial: serial, name: batch.name,
                               path: "\(ShareInbox.outboxRemote)/\(batch.name)")
            }
        }
    }

    /// Pull one batch's files, then delete it on the device. Runs on `queue`.
    private func pullBatch(serial: String, name: String, path: String) {
        defer { DispatchQueue.main.async { self.inFlight.remove(name) } }
        guard let entries = try? Adb.list(serial, path: path) else { return }
        // Not ready yet: the marker is written last, so its absence means files are still landing.
        // Leave the batch (do not delete); a later tick picks it up once the marker appears.
        guard entries.contains(where: { $0.name == ".ready" }) else { return }
        var pulled: [URL] = []
        for entry in entries where !entry.isDirectory && entry.name != ".ready" {
            let local = uniqueDestination(for: entry.name)
            do {
                try Adb.pull(serial, remotePath: "\(path)/\(entry.name)", localPath: local.path)
                pulled.append(local)
            } catch {
                AppBuild.log("share inbox: pull \(entry.name) failed: \(error)")
            }
        }
        // Whatever came through, drop the batch so it is not seen again. A file that failed to
        // pull is lost rather than retried forever — the user can share it again.
        _ = try? Adb.shell(serial, "rm -rf \(Adb.shellQuote(path))")
        guard !pulled.isEmpty else { return }
        AppBuild.log("share inbox: received \(pulled.count) item(s) from \(serial)")
        let files = pulled
        DispatchQueue.main.async { self.onReceived?(files) }
    }

    private func uniqueDestination(for name: String) -> URL {
        let cleaned = name.isEmpty ? "shared" : name
        var candidate = destination.appendingPathComponent(cleaned)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (cleaned as NSString).pathExtension
        let base = (cleaned as NSString).deletingPathExtension
        var n = 2
        repeat {
            let suffix = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            candidate = destination.appendingPathComponent(suffix)
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}
