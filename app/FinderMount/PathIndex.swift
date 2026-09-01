//
//  PathIndex.swift
//  Stable item identifiers for a storage that only has paths.
//
//  Finder identifies an item by its NSFileProviderItemIdentifier and expects that to survive a
//  rename or a move; the phone identifies a file by its path, which is exactly what a rename
//  changes. So each path that is ever shown gets a random identifier, and this table — one per
//  device, kept in the extension's container — remembers which is which. Renaming a directory
//  rewrites the paths of everything under it.
//
//  Losing the file is not fatal: unknown identifiers read as "no such item", the system drops
//  them, and the next listing mints fresh ones.
//

import FileProvider

final class PathIndex {
    private var pathForId: [String: String] = [:]
    private var idForPath: [String: String] = [:]
    private let lock = NSLock()
    private let file: URL
    private var dirty = false

    init(domainIdentifier: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        file = support.appendingPathComponent("index-\(domainIdentifier).json")
        if let data = try? Data(contentsOf: file),
           let table = try? JSONDecoder().decode([String: String].self, from: data) {
            pathForId = table
            for (id, path) in table { idForPath[path] = id }
        }
    }

    func identifier(for path: String) -> NSFileProviderItemIdentifier {
        if path == phoneRoot { return .rootContainer }
        lock.lock(); defer { lock.unlock() }
        if let id = idForPath[path] { return NSFileProviderItemIdentifier(id) }
        let id = UUID().uuidString
        idForPath[path] = id
        pathForId[id] = path
        dirty = true
        return NSFileProviderItemIdentifier(id)
    }

    func path(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return phoneRoot }
        lock.lock(); defer { lock.unlock() }
        return pathForId[identifier.rawValue]
    }

    /// The item moved (or was renamed): it and everything under it now live at `newPath`.
    func move(_ identifier: NSFileProviderItemIdentifier, to newPath: String) {
        lock.lock(); defer { lock.unlock() }
        guard let oldPath = pathForId[identifier.rawValue] else { return }
        let oldPrefix = oldPath + "/"
        for (id, path) in pathForId {
            if path == oldPath {
                rebind(id, to: newPath)
            } else if path.hasPrefix(oldPrefix) {
                rebind(id, to: newPath + path.dropFirst(oldPath.count))
            }
        }
        dirty = true
    }

    func remove(_ identifier: NSFileProviderItemIdentifier) {
        lock.lock(); defer { lock.unlock() }
        guard let path = pathForId[identifier.rawValue] else { return }
        let prefix = path + "/"
        for (id, p) in pathForId where p == path || p.hasPrefix(prefix) {
            pathForId[id] = nil
            idForPath[p] = nil
        }
        dirty = true
    }

    private func rebind(_ id: String, to newPath: String) {
        if let old = pathForId[id] { idForPath[old] = nil }
        pathForId[id] = newPath
        idForPath[newPath] = id
    }

    /// Write the table out if it changed. Called after each operation that could have; the
    /// table is small (one line per file ever shown) so this is cheap.
    func save() {
        lock.lock(); defer { lock.unlock() }
        guard dirty else { return }
        if let data = try? JSONEncoder().encode(pathForId) {
            try? data.write(to: file, options: .atomic)
            dirty = false
        }
    }
}
