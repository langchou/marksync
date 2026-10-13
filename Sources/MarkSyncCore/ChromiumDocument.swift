import CryptoKit
import Foundation

/// An editable Chromium `Bookmarks` file.
///
/// Unlike ``ChromiumBookmarks/write(_:)``, which builds a file from scratch, this keeps every
/// field Chrome wrote — `guid`, `sync_metadata`, `meta_info`, `date_last_used` … — and only
/// appends nodes. Chrome checks three things when it loads the file, and all three are kept
/// valid here:
///
/// * the three permanent roots `bookmark_bar`, `other` and `synced` must exist;
/// * every `id` must be a unique decimal integer (otherwise Chrome renumbers the whole tree);
/// * `checksum` is an MD5 over every node, in file order (see ``computeChecksum()``).
public final class ChromiumDocument {

    public enum DocumentError: Error, CustomStringConvertible {
        case notAnObject
        case unknownFolder(String)

        public var description: String {
            switch self {
            case .notAnObject: return "the Chromium bookmark file is not a JSON object"
            case .unknownFolder(let id): return "no folder with id \(id) in the Chromium bookmark file"
            }
        }
    }

    /// The permanent roots, in the order Chrome encodes and checksums them.
    public static let rootKeys = ["bookmark_bar", "other", "synced"]

    /// Chrome's fixed GUIDs for the permanent folders (`bookmark_node.cc`).
    static let rootGUIDs = [
        "bookmark_bar": "0bc5d13f-2cba-5d74-951f-3f233fe6c908",
        "other": "82b081ec-3dd3-529c-8475-ab6c344590dd",
        "synced": "4cf2e351-0e85-532b-bb37-df045d8f8d0f",
    ]
    static let rootTitles = ["bookmark_bar": "Bookmarks bar", "other": "Other bookmarks", "synced": "Mobile bookmarks"]

    private let object: NSMutableDictionary
    private var byID: [String: NSMutableDictionary] = [:]
    private var nextID: Int64 = 1

    /// An empty file with the three permanent roots.
    public convenience init() {
        try! self.init(data: Data(#"{"roots":{},"version":1}"#.utf8))
    }

    public init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? NSMutableDictionary else {
            throw DocumentError.notAnObject
        }
        self.object = object
        let roots = (object["roots"] as? NSMutableDictionary) ?? NSMutableDictionary()
        object["roots"] = roots
        for key in Self.rootKeys where roots[key] == nil {
            roots[key] = NSMutableDictionary(dictionary: [
                "children": NSMutableArray(),
                "date_added": ChromiumBookmarks.chromiumValue(from: Date()),
                "date_modified": "0",
                "guid": Self.rootGUIDs[key]!,
                "id": "",
                "name": Self.rootTitles[key]!,
                "type": "folder",
            ])
        }
        if object["version"] == nil { object["version"] = 1 }
        reindex()
    }

    public static func load(path: String) throws -> ChromiumDocument {
        guard FileManager.default.fileExists(atPath: path) else { return ChromiumDocument() }
        return try ChromiumDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private var roots: NSMutableDictionary { object["roots"] as! NSMutableDictionary }

    /// Indexes nodes by id and gives any node without a valid, unique integer id a fresh one.
    private func reindex() {
        byID = [:]
        var all: [NSMutableDictionary] = []
        func collect(_ node: NSMutableDictionary) {
            all.append(node)
            for case let child as NSMutableDictionary in (node["children"] as? NSArray) ?? [] { collect(child) }
        }
        // Permanent roots first so a brand-new file numbers them 1, 2, 3 like Chrome does;
        // any other root (`managed`, …) still shares the id space.
        let extraKeys = roots.allKeys.compactMap { $0 as? String }.filter { !Self.rootKeys.contains($0) }.sorted()
        for key in Self.rootKeys + extraKeys {
            if let root = roots[key] as? NSMutableDictionary { collect(root) }
        }
        var used: Set<Int64> = []
        var needsID: [NSMutableDictionary] = []
        for node in all {
            if let id = Int64("\(node["id"] ?? "")"), id > 0, used.insert(id).inserted {
                byID[String(id)] = node
            } else {
                needsID.append(node)
            }
        }
        nextID = (used.max() ?? 0) + 1
        for node in needsID { assignID(node) }
    }

    private func assignID(_ node: NSMutableDictionary) {
        let id = String(nextID)
        nextID += 1
        node["id"] = id
        byID[id] = node
    }

    /// The node id of a permanent root.
    public func rootID(_ key: String) -> String? {
        (roots[key] as? NSDictionary)?["id"] as? String
    }

    // MARK: - Reading

    /// Existing folders and URLs per slot, for ``BookmarkMerge/plan(source:target:)``.
    public func mergeTarget() -> [BookmarkSlot: BookmarkMerge.TargetFolder] {
        func folder(_ node: NSDictionary) -> BookmarkMerge.TargetFolder {
            var out = BookmarkMerge.TargetFolder(ref: node["id"] as? String ?? "", title: node["name"] as? String ?? "")
            for case let child as NSDictionary in (node["children"] as? NSArray) ?? [] {
                if (child["type"] as? String) == "folder" {
                    out.folders.append(folder(child))
                } else if let url = child["url"] as? String {
                    out.urls.append(url)
                }
            }
            return out
        }
        var out: [BookmarkSlot: BookmarkMerge.TargetFolder] = [:]
        for (key, slot) in [("bookmark_bar", BookmarkSlot.bar), ("other", .other), ("synced", .mobile)] {
            if let root = roots[key] as? NSDictionary { out[slot] = folder(root) }
        }
        return out
    }

    public func tree() throws -> BookmarkTree {
        try ChromiumBookmarks.parse(data())
    }

    // MARK: - Writing

    /// Appends `nodes` to the folder with id `parentID`.
    @discardableResult
    public func insert(_ nodes: [BookmarkNode], into parentID: String) throws -> Int {
        guard let parent = byID[parentID], (parent["type"] as? String) == "folder" else {
            throw DocumentError.unknownFolder(parentID)
        }
        let children = (parent["children"] as? NSMutableArray) ?? NSMutableArray()
        parent["children"] = children
        for node in nodes { children.add(encode(node)) }
        parent["date_modified"] = ChromiumBookmarks.chromiumValue(from: Date())
        return nodes.count
    }

    private func encode(_ node: BookmarkNode) -> NSMutableDictionary {
        let dict = NSMutableDictionary()
        assignID(dict)
        dict["guid"] = UUID().uuidString.lowercased()
        dict["name"] = node.title
        dict["date_added"] = ChromiumBookmarks.chromiumValue(from: NetscapeHTML.plausible(node.dateAdded) ?? Date())
        dict["date_last_used"] = "0"
        if let note = node.annotation, !note.isEmpty {
            dict["meta_info"] = NSMutableDictionary(dictionary: ["description": note])
        }
        if node.kind == .folder {
            dict["type"] = "folder"
            dict["date_modified"] = "0"
            dict["children"] = NSMutableArray(array: node.children.map { encode($0) })
        } else {
            dict["type"] = "url"
            dict["url"] = node.href
        }
        return dict
    }

    /// Chrome's bookmark checksum (`BookmarkCodec`): MD5 over each node in file order —
    /// `bookmark_bar`, `other`, `synced`, depth first — feeding the id (UTF-8), the title
    /// (UTF-16 code units, little-endian), the type and, for links, the URL.
    public func computeChecksum() -> String {
        var md5 = Insecure.MD5()
        func update(_ s: String) { md5.update(data: Data(s.utf8)) }
        func updateTitle(_ s: String) {
            var bytes = Data(capacity: s.utf16.count * 2)
            for unit in s.utf16 { bytes.append(UInt8(unit & 0xFF)); bytes.append(UInt8(unit >> 8)) }
            md5.update(data: bytes)
        }
        func visit(_ node: NSDictionary) {
            update(node["id"] as? String ?? "")
            updateTitle(node["name"] as? String ?? "")
            if (node["type"] as? String) == "url" {
                update("url")
                update(node["url"] as? String ?? "")
            } else {
                update("folder")
                for case let child as NSDictionary in (node["children"] as? NSArray) ?? [] { visit(child) }
            }
        }
        for key in Self.rootKeys { if let root = roots[key] as? NSDictionary { visit(root) } }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The file contents, with a freshly computed checksum.
    public func data() throws -> Data {
        object["checksum"] = computeChecksum()
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
