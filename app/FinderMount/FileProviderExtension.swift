//
//  FileProviderExtension.swift
//  The phone's storage as a Finder location.
//
//  A File Provider extension: fileproviderd launches this process (sandboxed, on demand) for
//  each registered domain and asks it for items, listings and file contents; Finder shows the
//  result under Locations, dragging a file out of it is a plain file copy and dropping one in is
//  a push. One domain per device — the domain identifier carries the adb serial, which is all
//  this needs to know.
//
//  The only link to the phone is the adb server on 127.0.0.1:5037, spoken to directly with the
//  same client the app uses (Adb.swift is compiled into both). The app is what starts that
//  server, so the mount is live while the app is; without it every request fails with
//  "server unreachable", which Finder shows as the folder being offline.
//

import FileProvider

@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    /// adb calls block on the socket; the system calls in on arbitrary threads and expects the
    /// completion later, so the work is taken off its thread.
    static let queue = DispatchQueue(label: "finder-mount.adb", qos: .userInitiated,
                                     attributes: .concurrent)

    private let domain: NSFileProviderDomain
    private let serial: String
    private let index: PathIndex

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        serial = AdbDevice.serial(fromDomainIdentifier: domain.identifier.rawValue)
        index = PathIndex(domainIdentifier: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() { index.save() }

    static func translate(_ error: Error) -> Error {
        if let adb = error as? AdbError {
            switch adb {
            case .noServer: return NSFileProviderError(.serverUnreachable)
            default: return NSFileProviderError(.noSuchItem)
            }
        }
        return error
    }

    /// The item at `path` as the device currently describes it, or nil if it is gone.
    private func stat(_ path: String) throws -> PhoneItem? {
        if path == phoneRoot { return PhoneItem.root }
        guard let entry = try Adb.stat(serial, path: path) else { return nil }
        return PhoneItem(path: path, entry: entry, index: index)
    }

    private func path(for identifier: NSFileProviderItemIdentifier) throws -> String {
        guard let path = index.path(for: identifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return path
    }

    // MARK: - reading

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        FileProviderExtension.queue.async {
            do {
                guard let item = try self.stat(try self.path(for: identifier)) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                completionHandler(item, nil)
            } catch {
                completionHandler(nil, FileProviderExtension.translate(error))
            }
        }
        return Progress()
    }

    func fetchContents(for identifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void)
        -> Progress {
        let progress = Progress(totalUnitCount: 100)
        FileProviderExtension.queue.async {
            do {
                let path = try self.path(for: identifier)
                guard let item = try self.stat(path) else { throw NSFileProviderError(.noSuchItem) }
                // The system takes ownership of the file at this URL; it has to live in the
                // domain's own temporary directory for that hand-off to be a rename.
                let dir = try NSFileProviderManager(for: self.domain)?.temporaryDirectoryURL()
                    ?? FileManager.default.temporaryDirectory
                let local = dir.appendingPathComponent(UUID().uuidString)
                let total = max(item.size, 1)
                try Adb.pull(self.serial, remotePath: path, localPath: local.path) { received in
                    progress.completedUnitCount = Int64(min(100, received * 100 / total))
                }
                progress.completedUnitCount = 100
                completionHandler(local, item, nil)
            } catch {
                completionHandler(nil, nil, FileProviderExtension.translate(error))
            }
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet {
            return PhoneEnumerator(serial: serial, path: nil, index: index)
        }
        return PhoneEnumerator(serial: serial, path: try path(for: containerItemIdentifier),
                               index: index)
    }

    // MARK: - writing

    /// A file dropped in (contents given) or a New Folder (a folder type, no contents).
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
                    contents url: URL?, options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                  Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        FileProviderExtension.queue.async {
            do {
                let parent = try self.path(for: itemTemplate.parentItemIdentifier)
                let path = parent + "/" + itemTemplate.filename
                if itemTemplate.contentType == .folder {
                    try Adb.makeDirectory(self.serial, path: path)
                } else if let url {
                    let total = max(Int((try? url.resourceValues(forKeys: [.fileSizeKey]))?
                                            .fileSize ?? 0), 1)
                    try Adb.push(self.serial, localPath: url.path, remotePath: path) { sent in
                        progress.completedUnitCount = Int64(min(100, sent * 100 / total))
                    }
                } else {
                    // A placeholder with no bytes yet (Finder does this for some saves): make
                    // an empty file so the item exists; the contents arrive via modifyItem.
                    _ = try Adb.shell(self.serial, ": > \(Adb.shellQuote(path))")
                }
                progress.completedUnitCount = 100
                guard let item = try self.stat(path) else { throw NSFileProviderError(.noSuchItem) }
                self.index.save()
                completionHandler(item, [], false, nil)
            } catch {
                completionHandler(nil, [], false, FileProviderExtension.translate(error))
            }
        }
        return progress
    }

    /// New contents are pushed over the file; a new name or parent is a `mv`. Anything else
    /// Finder wants to change (dates, tags, favorites) has nowhere to go on the phone and is
    /// accepted silently.
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                  Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        FileProviderExtension.queue.async {
            do {
                var path = try self.path(for: item.itemIdentifier)
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let parent = try self.path(for: item.parentItemIdentifier)
                    let newPath = parent + "/" + item.filename
                    if newPath != path {
                        try Adb.move(self.serial, from: path, to: newPath)
                        self.index.move(item.itemIdentifier, to: newPath)
                        path = newPath
                    }
                }
                if changedFields.contains(.contents), let newContents {
                    let total = max(Int((try? newContents.resourceValues(forKeys: [.fileSizeKey]))?
                                            .fileSize ?? 0), 1)
                    try Adb.push(self.serial, localPath: newContents.path, remotePath: path) { sent in
                        progress.completedUnitCount = Int64(min(100, sent * 100 / total))
                    }
                }
                progress.completedUnitCount = 100
                guard let updated = try self.stat(path) else { throw NSFileProviderError(.noSuchItem) }
                self.index.save()
                completionHandler(updated, [], false, nil)
            } catch {
                completionHandler(nil, [], false, FileProviderExtension.translate(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        FileProviderExtension.queue.async {
            do {
                let path = try self.path(for: identifier)
                guard path != phoneRoot else { throw NSFileProviderError(.noSuchItem) }
                try Adb.remove(self.serial, path: path)
                self.index.remove(identifier)
                self.index.save()
                completionHandler(nil)
            } catch {
                completionHandler(FileProviderExtension.translate(error))
            }
        }
        return Progress()
    }
}
