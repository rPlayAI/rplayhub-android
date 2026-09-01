//
//  PhoneItem.swift
//  One entry of the phone's storage, as Finder sees it.
//

import FileProvider
import UniformTypeIdentifiers

/// The directory the mount exposes. Shared storage is what a person means by "the phone's
/// files"; /data is not readable as shell anyway.
let phoneRoot = "/sdcard"

final class PhoneItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let path: String
    let isDirectory: Bool
    let size: Int
    let modified: Date?

    /// The entry at `path`, identified through `index` (its parent's identifier too).
    init(path: String, entry: Adb.DirEntry, index: PathIndex) {
        self.path = path
        itemIdentifier = index.identifier(for: path)
        parentItemIdentifier = index.identifier(for: (path as NSString).deletingLastPathComponent)
        // A symlink to a directory lists as a directory; `ls` says "l" and a zero size for it.
        isDirectory = entry.isDirectory || (entry.isLink && entry.size == 0)
        size = entry.size
        modified = PhoneItem.parseDate(entry.modified)
    }

    private init(root: Void) {
        path = phoneRoot
        itemIdentifier = .rootContainer
        parentItemIdentifier = .rootContainer
        isDirectory = true
        size = 0
        modified = nil
    }

    static let root = PhoneItem(root: ())

    var filename: String { (path as NSString).lastPathComponent }

    var contentType: UTType {
        if isDirectory { return .folder }
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = [.allowsReading, .allowsWriting,
                                                    .allowsRenaming, .allowsReparenting,
                                                    .allowsDeleting]
        if isDirectory { caps.formUnion([.allowsContentEnumerating, .allowsAddingSubItems]) }
        if itemIdentifier == .rootContainer {
            caps = [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        return caps
    }

    var documentSize: NSNumber? { isDirectory ? nil : NSNumber(value: size) }
    var contentModificationDate: Date? { modified }

    /// Size and mtime together stand in for a content hash; `ls` gives nothing better and it is
    /// exactly what rsync trusts too.
    var itemVersion: NSFileProviderItemVersion {
        let stamp = Data("\(size)|\(modified?.timeIntervalSince1970 ?? 0)".utf8)
        return NSFileProviderItemVersion(contentVersion: stamp, metadataVersion: stamp)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func parseDate(_ s: String) -> Date? { dateFormatter.date(from: s) }
}
