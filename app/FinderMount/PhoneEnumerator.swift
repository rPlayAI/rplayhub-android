//
//  PhoneEnumerator.swift
//  Lists one directory of the phone for Finder.
//
//  There is no change feed from the device, so enumerateChanges always reports "nothing new"
//  under the same anchor; Finder re-enumerates a folder when it is opened, which is what refreshes
//  it. The working set (the system's "everything worth tracking") is empty for the same reason.
//

import FileProvider

final class PhoneEnumerator: NSObject, NSFileProviderEnumerator {
    private let serial: String
    private let path: String?          // nil: the working set
    private let index: PathIndex

    init(serial: String, path: String?, index: PathIndex) {
        self.serial = serial
        self.path = path
        self.index = index
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        guard let path else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let serial = self.serial, index = self.index
        FileProviderExtension.queue.async {
            do {
                let entries = try Adb.list(serial, path: path)
                let items = entries.map {
                    PhoneItem(path: path + "/" + $0.name, entry: $0, index: index)
                }
                index.save()
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(FileProviderExtension.translate(error))
            }
        }
    }

    /// The anchor is this extension process's launch token. There is no change feed, so while
    /// the process lives nothing ever changes; once it has been relaunched the anchor Finder
    /// holds is unknown, and "expired" makes it re-list the folder in full — which is also how
    /// a rebuilt extension gets its new item metadata into the system's database.
    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        if anchor == PhoneEnumerator.anchor {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(PhoneEnumerator.anchor)
    }

    private static let anchor = NSFileProviderSyncAnchor(Data(UUID().uuidString.utf8))
}
