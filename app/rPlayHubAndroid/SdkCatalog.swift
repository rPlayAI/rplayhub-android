//
//  SdkCatalog.swift
//  Google's SDK repository index, read directly — no Android Studio, no sdkmanager, no JDK.
//
//  rPlayHub's point is to give someone an Android VM without installing an IDE, so the pieces the
//  emulator needs (the engine, a system image) are fetched on demand from the same index
//  sdkmanager reads, and Google's licence is presented and recorded here rather than bundled with
//  anything. We redistribute nothing: the bytes come from dl.google.com to the user's machine.
//
//  The index is XML:
//
//      <remotePackage path="emulator">
//        <revision><major/><minor/><micro/></revision>
//        <display-name>Android Emulator</display-name>
//        <uses-license ref="android-sdk-license"/>
//        <archives><archive>
//          <complete><size/><checksum type="sha1"/><url/></complete>
//          <host-os>macosx</host-os><host-arch>aarch64</host-arch>
//        </archive></archives>
//      </remotePackage>
//
//  Only a handful of fields matter, and XMLParser on a 400 KB document is cheap, so this reads it
//  with a small event-driven parser rather than pulling in a dependency.
//

import Foundation

/// One downloadable SDK package for this host.
struct SdkPackage: Equatable {
    /// The sdkmanager path, ';'-separated — "emulator", "system-images;android-35;google_apis;arm64-v8a".
    let path: String
    let displayName: String
    let revision: String
    /// Absolute download URL (the index carries a relative one against its own base).
    let url: URL
    let size: Int64
    let checksum: String
    let checksumKind: String        // "sha1" or "sha256"
    let licenseId: String?

    /// Where this package installs under the SDK root: the path's segments as directories, which
    /// is exactly the layout sdkmanager produces (`system-images/android-35/google_apis/arm64-v8a`).
    var installSubpath: String { path.split(separator: ";").joined(separator: "/") }

    /// API level parsed out of a system-image path, for sorting.
    var apiLevel: Int? {
        guard let seg = path.split(separator: ";").first(where: { $0.hasPrefix("android-") })
        else { return nil }
        return Int(seg.dropFirst("android-".count).prefix { $0.isNumber })
    }

    /// The API as Google writes it, minor included — "37.2", not "37". Three images can share a
    /// major (android-37.0/37.1/37.2), so a label built from `apiLevel` alone repeats itself.
    var apiLabel: String? {
        guard let seg = path.split(separator: ";").first(where: { $0.hasPrefix("android-") })
        else { return nil }
        return String(seg.dropFirst("android-".count))
    }

    /// Sortable: 37.2 above 37.0, and both above 36.
    var apiOrder: Double {
        guard let label = apiLabel else { return 0 }
        let parts = label.split(separator: ".")
        let major = Double(parts.first.map(String.init) ?? "") ?? 0
        let minor = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
        return major + minor / 100
    }

    /// "google_apis", "google_apis_playstore", "default"…
    var tag: String? {
        let parts = path.split(separator: ";")
        return parts.count >= 3 ? String(parts[2]) : nil
    }
}

/// The catalog: which indexes to read, and what came back.
enum SdkCatalog {
    static let base = URL(string: "https://dl.google.com/android/repository/")!

    /// The main index (tools, emulator, platform-tools) and the system-image indexes. Google
    /// splits images by vendor tag across several files; these are the ones with arm64 phone
    /// images on them.
    static let mainIndex = "repository2-3.xml"
    static let systemImageIndexes = [
        "sys-img/google_apis/sys-img2-3.xml",
        "sys-img/google_apis_playstore/sys-img2-3.xml",
        "sys-img/android/sys-img2-3.xml",
    ]

    /// This machine's host-arch as the index spells it.
    static var hostArch: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x64"
        #endif
    }

    struct Index {
        var packages: [SdkPackage] = []
        /// Licence id → full text, for the acceptance sheet.
        var licenses: [String: String] = [:]
    }

    /// Fetch and parse one index file.
    static func fetch(_ name: String) async throws -> Index {
        let url = URL(string: name, relativeTo: base)!
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SdkError.http(http.statusCode, url.absoluteString)
        }
        let parser = IndexParser(base: url)
        guard let xml = XMLParser(data: data) as XMLParser? else { throw SdkError.parse(name) }
        xml.delegate = parser
        guard xml.parse() else { throw SdkError.parse(name) }
        return Index(packages: parser.packages, licenses: parser.licenses)
    }

    /// Everything this host can install: the main index plus every system-image index, merged.
    static func fetchAll() async throws -> Index {
        var merged = Index()
        var indexes = [mainIndex]
        indexes.append(contentsOf: systemImageIndexes)
        for name in indexes {
            // One bad index (Google retires them occasionally) must not sink the whole catalog.
            guard let one = try? await fetch(name) else { continue }
            merged.packages.append(contentsOf: one.packages)
            merged.licenses.merge(one.licenses) { a, _ in a }
        }
        guard !merged.packages.isEmpty else { throw SdkError.parse("no packages in any index") }
        return merged
    }

    /// The emulator to install: the newest one on the ordinary SDK licence. The index also
    /// carries preview-channel builds (they reference `android-sdk-preview-license`), and a
    /// first-run install should not silently land the user on a preview.
    static func emulator(in index: Index) -> SdkPackage? {
        let all = index.packages.filter { $0.path == "emulator" }
        let stable = all.filter { $0.licenseId != "android-sdk-preview-license" }
        let pool = stable.isEmpty ? all : stable
        return pool.max { $0.revision.compare($1.revision, options: .numeric) == .orderedAscending }
    }

    /// Installable phone system images for this host's ABI, newest API first. Preview/beta images
    /// are dropped — a first-run install should land on something released.
    static func systemImages(in index: Index) -> [SdkPackage] {
        let abi = hostArch == "aarch64" ? "arm64-v8a" : "x86_64"
        return index.packages
            .filter { $0.path.hasPrefix("system-images;") && $0.path.hasSuffix(abi) }
            .filter { !$0.path.contains("-beta") && !$0.path.contains("-rc") && !$0.path.contains("ext") }
            // google_apis (rootable) and google_apis_playstore only. The _ps16k variants are
            // 16 KB-page-size builds that duplicate every API level and mean nothing to someone
            // who just wants a VM.
            .filter { $0.tag == "google_apis" || $0.tag == "google_apis_playstore" }
            .sorted { $0.apiOrder > $1.apiOrder }
    }

    // MARK: - parsing

    private final class IndexParser: NSObject, XMLParserDelegate {
        private(set) var packages: [SdkPackage] = []
        private(set) var licenses: [String: String] = [:]

        private let base: URL
        init(base: URL) { self.base = base }

        private var text = ""
        private var licenseId: String?

        // current package
        private var path: String?
        private var displayName = ""
        private var revision: [String] = []
        private var usesLicense: String?

        // current archive
        private var inArchive = false
        private var inComplete = false
        private var archiveHostOS: String?
        private var archiveHostArch: String?
        private var url: String?
        private var size: Int64 = 0
        private var checksum = ""
        private var checksumKind = "sha1"
        /// Archives of the current package that match this host.
        private var candidate: (url: String, size: Int64, sum: String, kind: String)?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attr: [String: String]) {
            text = ""
            let tag = name.contains(":") ? String(name.split(separator: ":").last!) : name
            switch tag {
            case "license":
                licenseId = attr["id"]
            case "remotePackage":
                path = attr["path"]
                displayName = ""; revision = []; usesLicense = nil; candidate = nil
            case "uses-license":
                usesLicense = attr["ref"]
            case "archive":
                inArchive = true; archiveHostOS = nil; archiveHostArch = nil
            case "complete":
                inComplete = true; url = nil; size = 0; checksum = ""; checksumKind = "sha1"
            case "checksum":
                checksumKind = attr["type"] ?? "sha1"
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let tag = name.contains(":") ? String(name.split(separator: ":").last!) : name
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch tag {
            case "license":
                if let id = licenseId { licenses[id] = value }
                licenseId = nil
            case "display-name":
                if path != nil { displayName = value }
            case "major", "minor", "micro":
                if path != nil, inArchive == false { revision.append(value) }
            case "size":
                if inComplete { size = Int64(value) ?? 0 }
            case "checksum":
                if inComplete { checksum = value }
            case "url":
                if inComplete { url = value }
            case "complete":
                inComplete = false
            case "host-os":
                archiveHostOS = value
            case "host-arch":
                archiveHostArch = value
            case "archive":
                // Keep the archive for this host. A package with no host-os at all (the system
                // images) is host-neutral and counts for everyone; one that names an arch must
                // match ours.
                let osOK = archiveHostOS == nil || archiveHostOS == "macosx"
                let archOK = archiveHostArch == nil || archiveHostArch == SdkCatalog.hostArch
                if osOK, archOK, let u = url, !checksum.isEmpty, size > 0, candidate == nil {
                    candidate = (u, size, checksum, checksumKind)
                }
                inArchive = false
            case "remotePackage":
                if let p = path, let c = candidate,
                   let full = URL(string: c.url, relativeTo: base)?.absoluteURL {
                    packages.append(SdkPackage(
                        path: p, displayName: displayName.isEmpty ? p : displayName,
                        revision: revision.joined(separator: "."), url: full, size: c.size,
                        checksum: c.sum, checksumKind: c.kind, licenseId: usesLicense))
                }
                path = nil; candidate = nil
            default:
                break
            }
        }
    }
}

enum SdkError: Error, CustomStringConvertible {
    case http(Int, String)
    case parse(String)
    case checksum(expected: String, got: String)
    case extract(String)
    case cancelled
    case noPackage(String)

    var description: String {
        switch self {
        case .http(let code, let url):    return "HTTP \(code) from \(url)"
        case .parse(let what):            return "could not read \(what)"
        case .checksum(let e, let g):     return "checksum mismatch (expected \(e.prefix(12))…, got \(g.prefix(12))…)"
        case .extract(let m):             return "could not unpack the download: \(m)"
        case .cancelled:                  return "cancelled"
        case .noPackage(let p):           return "\(p) is not in Google's index for this Mac"
        }
    }
}
