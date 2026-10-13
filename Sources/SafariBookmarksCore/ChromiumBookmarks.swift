import Foundation

/// Reader/writer for the Chromium `Bookmarks` JSON format, used by Chrome, Edge, Brave,
/// Chromium, Vivaldi, Opera and most other Blink-based browsers.
public enum ChromiumBookmarks {

    public enum ParseError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case missingRoots

        public var description: String {
            switch self {
            case .invalidJSON(let m): return "invalid Chromium bookmark JSON: \(m)"
            case .missingRoots: return "Chromium bookmark JSON has no \"roots\" object"
            }
        }
    }

    /// Chromium timestamps are microseconds since 1601-01-01T00:00:00Z.
    private static let windowsEpochOffset: TimeInterval = 11_644_473_600

    public static func date(fromChromium value: Any?) -> Date? {
        let raw: Double?
        switch value {
        case let s as String: raw = Double(s)
        case let d as Double: raw = d
        case let i as Int: raw = Double(i)
        default: raw = nil
        }
        guard let micros = raw, micros > 0 else { return nil }
        return Date(timeIntervalSince1970: micros / 1_000_000 - windowsEpochOffset)
    }

    public static func chromiumValue(from date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 + windowsEpochOffset) * 1_000_000))
    }

    // MARK: - Reading

    public static func parse(_ data: Data) throws -> BookmarkTree {
        let object: [String: Any]
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ParseError.invalidJSON("top-level value is not an object")
            }
            object = dict
        } catch let e as ParseError {
            throw e
        } catch {
            let ns = error as NSError
            let detail = ns.domain == NSCocoaErrorDomain ? "not valid JSON" : ns.localizedDescription
            throw ParseError.invalidJSON(detail)
        }
        guard let roots = object["roots"] as? [String: Any] else { throw ParseError.missingRoots }

        let order = ["bookmark_bar", "other", "synced", "mobile", "managed"]
        var out: [BookmarkTree.RootFolder] = []
        for key in order where roots[key] != nil {
            guard let node = parseNode(roots[key]) else { continue }
            out.append(.init(id: key, title: node.title.isEmpty ? defaultTitle(for: key) : node.title, node: node))
        }
        // Any unexpected extra roots.
        for (key, value) in roots where !order.contains(key) {
            guard let node = parseNode(value) else { continue }
            out.append(.init(id: key, title: node.title.isEmpty ? key : node.title, node: node))
        }
        return BookmarkTree(source: "chromium", roots: out)
    }

    private static func defaultTitle(for key: String) -> String {
        switch key {
        case "bookmark_bar": return "Bookmarks bar"
        case "other": return "Other bookmarks"
        case "synced": return "Mobile bookmarks"
        default: return key
        }
    }

    private static func parseNode(_ any: Any?) -> BookmarkNode? {
        guard let dict = any as? [String: Any] else { return nil }
        let type = (dict["type"] as? String) ?? "url"
        let name = (dict["name"] as? String) ?? ""
        let dateAdded = date(fromChromium: dict["date_added"])
        let meta = (dict["meta_info"] as? [String: Any])?["description"] as? String
        if type == "folder" {
            let children = (dict["children"] as? [Any] ?? []).compactMap { parseNode($0) }
            return BookmarkNode(kind: .folder, title: name, dateAdded: dateAdded, annotation: meta, children: children)
        }
        let url = (dict["url"] as? String) ?? ""
        return BookmarkNode(kind: .link, title: name.isEmpty ? url : name, url: url, dateAdded: dateAdded, annotation: meta)
    }

    // MARK: - Writing

    /// Serialises a tree into the Chromium `Bookmarks` JSON shape.
    /// Emits `bookmark_bar`, `other` and `synced` roots as Chromium expects.
    public static func write(_ tree: BookmarkTree) throws -> Data {
        var roots: [String: Any] = [:]
        for root in tree.roots {
            roots[root.id] = encodeNode(root.node, id: nextID())
        }
        let object: [String: Any] = [
            "checksum": "",
            "roots": roots,
            "version": 1,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static var counter = 0
    private static func nextID() -> String {
        counter += 1
        return String(counter)
    }

    private static func encodeNode(_ node: BookmarkNode, id: String) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": node.title,
        ]
        if let d = NetscapeHTML.plausible(node.dateAdded) { dict["date_added"] = chromiumValue(from: d) }
        if let a = node.annotation, !a.isEmpty {
            dict["meta_info"] = ["description": a]
        }
        if node.kind == .folder {
            dict["type"] = "folder"
            dict["children"] = node.children.enumerated().map { idx, child in
                encodeNode(child, id: "\(id)-\(idx)")
            }
        } else {
            dict["type"] = "url"
            dict["url"] = node.href
        }
        return dict
    }
}
