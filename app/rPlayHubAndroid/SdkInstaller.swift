//
//  SdkInstaller.swift
//  Downloading the emulator and a system image on demand, the way sdkmanager would — without
//  sdkmanager, Android Studio, or a JDK.
//
//  Nothing is redistributed: the bytes come from dl.google.com straight to the user's machine,
//  and Google's licence is shown and recorded (`$SDK/licenses/<id>`, the SHA-1 of the licence
//  text, exactly the file sdkmanager writes) so a later sdkmanager or Studio agrees the terms
//  were accepted.
//
//  The SDK root defaults to a folder this app owns — no admin rights, no PATH surgery — and is
//  remembered as `AndroidSdkRoot`, which `AndroidSdk` already prefers over every other guess.
//

import CryptoKit
import Foundation

actor SdkInstaller {
    /// Where we install when the user has no SDK of their own. Under Application Support so it
    /// survives an app update and needs no privileges.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rPlayHub/android-sdk", isDirectory: true)
    }

    /// Where installs go: the user's chosen/dicovered SDK if it is writable, else ours.
    static var installRoot: URL {
        if let chosen = UserDefaults.standard.string(forKey: AndroidSdk.rootDefaultsKey),
           !chosen.isEmpty {
            return URL(fileURLWithPath: chosen)
        }
        if let found = AndroidSdk.root,
           FileManager.default.isWritableFile(atPath: found.path) {
            return found
        }
        return defaultRoot
    }

    enum Phase: Equatable {
        case waiting
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case done
    }

    /// Progress for the UI. Called on the main queue.
    typealias Progress = @Sendable (Phase) -> Void

    /// Install one package into `root`. Returns the directory it landed in.
    @discardableResult
    func install(_ package: SdkPackage, into root: URL, license: String?,
                 progress: @escaping Progress) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let license, let id = package.licenseId {
            try? Self.recordLicence(id: id, text: license, root: root)
        }

        await MainActor.run { progress(.waiting) }
        let zip = try await download(package, progress: progress)
        defer { try? fm.removeItem(at: zip) }

        await MainActor.run { progress(.verifying) }
        let sum = try Self.checksum(of: zip, kind: package.checksumKind)
        guard sum.caseInsensitiveCompare(package.checksum) == .orderedSame else {
            throw SdkError.checksum(expected: package.checksum, got: sum)
        }

        await MainActor.run { progress(.installing) }
        let destination = root.appendingPathComponent(package.installSubpath, isDirectory: true)
        try Self.unpack(zip, to: destination)
        await MainActor.run { progress(.done) }
        return destination
    }

    // MARK: - download

    private func download(_ package: SdkPackage, progress: @escaping Progress) async throws -> URL {
        let (stream, continuation) = AsyncThrowingStream<URL, Error>.makeStream()
        let delegate = DownloadDelegate(total: package.size, progress: progress,
                                        continuation: continuation)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600      // a 2 GB image on a slow line
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.downloadTask(with: package.url).resume()
        for try await url in stream { return url }
        throw SdkError.cancelled
    }

    /// URLSession hands the finished file to the delegate and deletes it when the callback
    /// returns, so it is moved somewhere of our own before the stream yields it.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let total: Int64
        private let progress: Progress
        private let continuation: AsyncThrowingStream<URL, Error>.Continuation
        private var lastReport = Date.distantPast

        init(total: Int64, progress: @escaping Progress,
             continuation: AsyncThrowingStream<URL, Error>.Continuation) {
            self.total = total
            self.progress = progress
            self.continuation = continuation
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData written: Int64, totalBytesWritten got: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            // Twice a second is plenty for a progress bar and keeps the main queue quiet.
            guard Date().timeIntervalSince(lastReport) > 0.5 else { return }
            lastReport = Date()
            let cap = expected > 0 ? expected : total
            DispatchQueue.main.async { self.progress(.downloading(received: got, total: cap)) }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                continuation.finish(throwing: SdkError.http(http.statusCode,
                                                            downloadTask.originalRequest?.url?.absoluteString ?? ""))
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("rplayhub-sdk-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: location, to: tmp)
                continuation.yield(tmp)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation.finish(throwing: error) }
        }
    }

    // MARK: - verify / unpack

    /// Streamed so a 2 GB image is not read into memory.
    static func checksum(of file: URL, kind: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1(), sha256 = SHA256()
        let wantsSha256 = kind.lowercased().contains("256")
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            if wantsSha256 { sha256.update(data: chunk) } else { sha1.update(data: chunk) }
        }
        let digest: [UInt8] = wantsSha256 ? Array(sha256.finalize()) : Array(sha1.finalize())
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Unpack with `ditto`, which handles the zips Google ships (symlinks, exec bits) where
    /// Foundation's unarchiver does not. The archive's single top-level directory becomes the
    /// destination itself — `emulator/…` in the zip is `$SDK/emulator/…` on disk.
    static func unpack(_ zip: URL, to destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("rplayhub-unzip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        let errors = Pipe()
        ditto.standardError = errors
        try ditto.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw SdkError.extract(message.isEmpty ? "ditto exited \(ditto.terminationStatus)" : message)
        }

        var source = staging
        let entries = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        let directories = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if entries.count == 1, directories.count == 1 { source = directories[0] }

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
    }

    /// `$SDK/licenses/<id>` holding the SHA-1 of the licence text — the same file and format
    /// sdkmanager writes, so a later sdkmanager/Studio run sees the terms as accepted.
    static func recordLicence(id: String, text: String, root: URL) throws {
        let dir = root.appendingPathComponent("licenses", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = Insecure.SHA1.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
        try (hash + "\n").write(to: dir.appendingPathComponent(id), atomically: true, encoding: .utf8)
    }

    /// Is this package already installed under `root`? A cheap existence check, which is all the
    /// UI needs to say "Installed" instead of offering a 2 GB download again.
    static func isInstalled(_ package: SdkPackage, root: URL) -> Bool {
        let dir = root.appendingPathComponent(package.installSubpath, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return !contents.isEmpty
    }
}
