import Foundation

/// Text rendering of a bookmark tree.
public enum TextOutput {

    public static func render(_ tree: BookmarkTree, maxDepth: Int? = nil, limit: Int? = nil) -> String {
        var lines: [String] = []
        lines.append("source: \(tree.source)   roots: \(tree.roots.count)   bookmarks: \(tree.linkCount)   folders: \(tree.folderCount)")
        for root in tree.roots {
            lines.append("")
            lines.append("▸ \(root.title.isEmpty ? root.id : root.title)")
            var emitted = 0
            root.node.walk { node, depth in
                guard depth > 0 else { return }
                if let maxDepth, depth > maxDepth { return }
                if let limit, emitted >= limit { return }
                emitted += 1
                let pad = String(repeating: "  ", count: depth)
                switch node.kind {
                case .folder:
                    lines.append("\(pad)📁 \(node.title)")
                case .link:
                    let title = node.title.isEmpty ? node.href : node.title
                    lines.append("\(pad)• \(title)")
                    lines.append("\(pad)  \(node.href)")
                }
            }
            if let limit, emitted >= limit {
                lines.append("  … output limited to \(limit) entries (raise with --indent <n>)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// JSON serialisation of trees and ad-hoc payloads.
public enum JSONOutput {

    public static func string(for tree: BookmarkTree, pretty: Bool = true) throws -> String {
        let object = encode(tree)
        return try string(object, pretty: pretty)
    }

    public static func string(_ object: Any, pretty: Bool = true) throws -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func encode(_ tree: BookmarkTree) -> [String: Any] {
        [
            "source": tree.source,
            "bookmarks": tree.linkCount,
            "folders": tree.folderCount,
            "roots": tree.roots.map { root -> [String: Any] in
                ["id": root.id, "title": root.title, "children": root.node.children.map(encode)]
            },
        ]
    }

    static func encode(_ node: BookmarkNode) -> [String: Any] {
        var dict: [String: Any] = ["type": node.kind.rawValue, "title": node.title]
        if let url = node.url { dict["url"] = url }
        if let d = node.dateAdded { dict["date_added"] = Int(d.timeIntervalSince1970) }
        if let a = node.annotation { dict["annotation"] = a }
        if node.isFolder { dict["children"] = node.children.map(encode) }
        return dict
    }

    /// Decodes the JSON this tool emits (and the `{"roots": …}` shape).
    public static func decodeTree(_ data: Data) throws -> BookmarkTree {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChromiumBookmarks.ParseError.invalidJSON("top level is not an object")
        }
        guard let rootArray = object["roots"] as? [Any] else {
            throw ChromiumBookmarks.ParseError.missingRoots
        }
        var roots: [BookmarkTree.RootFolder] = []
        for entry in rootArray {
            guard let dict = entry as? [String: Any] else { continue }
            let id = (dict["id"] as? String) ?? "root"
            let title = (dict["title"] as? String) ?? id
            let children = (dict["children"] as? [Any] ?? []).compactMap(decodeNode)
            roots.append(.init(id: id, title: title, node: .folder(title, children: children)))
        }
        return BookmarkTree(source: (object["source"] as? String) ?? "json", roots: roots)
    }

    static func decodeNode(_ any: Any) -> BookmarkNode? {
        guard let dict = any as? [String: Any] else { return nil }
        let title = (dict["title"] as? String) ?? ""
        let date = (dict["date_added"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let annotation = dict["annotation"] as? String
        if (dict["type"] as? String) == "folder" {
            let children = (dict["children"] as? [Any] ?? []).compactMap(decodeNode)
            return BookmarkNode(kind: .folder, title: title, dateAdded: date, annotation: annotation, children: children)
        }
        guard let url = dict["url"] as? String else { return nil }
        return BookmarkNode(kind: .link, title: title.isEmpty ? url : title, url: url, dateAdded: date, annotation: annotation)
    }
}

/// Writing output either to stdout or a file.
public enum Output {
    public static func write(_ data: Data, to path: String?) throws {
        guard let path else {
            FileHandle.standardOutput.write(data)
            if data.last != 0x0A { FileHandle.standardOutput.write(Data([0x0A])) }
            return
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Serialisation by requested format name.
public enum Serialize {
    public static func data(_ tree: BookmarkTree, format: String) throws -> Data {
        switch format {
        case "html", "netscape", "bookmarks.html":
            return Data(NetscapeHTML.write(tree).utf8)
        case "chromium", "chrome", "edge", "brave", "json-chromium":
            return try ChromiumBookmarks.write(tree)
        case "json", "tree":
            return Data(try JSONOutput.string(for: tree).utf8)
        default:
            throw BookmarkError.unsupportedFormat(format)
        }
    }
}

/// Tree filtering shared by export and import.
public enum Filtering {

    /// Keeps only folders whose title matches `only`, drops folders matching `exclude`,
    /// optionally wraps the result in a new titled folder, or flattens all nesting.
    public static func apply(
        _ tree: BookmarkTree,
        only: String?,
        exclude: String?,
        wrapTitle: String?,
        flatten: Bool
    ) -> BookmarkTree {
        var roots = tree.roots
        if let only {
            let needle = only.lowercased()
            roots = roots.compactMap { root in
                let kept = filterKeep(root.node, needle: needle)
                return kept.map { BookmarkTree.RootFolder(id: root.id, title: root.title, node: $0) }
            }
        }
        if let exclude {
            let needle = exclude.lowercased()
            roots = roots.map { BookmarkTree.RootFolder(id: $0.id, title: $0.title, node: filterDrop($0.node, needle: needle)) }
        }
        if flatten {
            let all = roots.flatMap { root -> [BookmarkNode] in
                var links: [BookmarkNode] = []
                root.node.walk { node, _ in if node.kind == .link { links.append(node) } }
                return links
            }
            roots = [.init(id: "flattened", title: "All Bookmarks", node: .folder("All Bookmarks", children: all))]
        }
        if let wrapTitle, !wrapTitle.isEmpty {
            let children = roots.map(\.node)
            roots = [.init(id: "imported", title: wrapTitle, node: .folder(wrapTitle, children: children))]
        }
        return BookmarkTree(source: tree.source, roots: roots)
    }

    /// Keeps a folder when it matches `needle` (keeping its whole subtree), otherwise keeps
    /// the descendants that match. A folder whose title matches is exported in full —
    /// `--only dev` should give you the *contents* of the Dev folder, not just its name.
    private static func filterKeep(_ node: BookmarkNode, needle: String) -> BookmarkNode? {
        if node.kind == .link {
            let matches = node.title.lowercased().contains(needle) || node.href.lowercased().contains(needle)
            return matches ? node : nil
        }
        if node.title.lowercased().contains(needle) { return node }
        let kids = node.children.compactMap { filterKeep($0, needle: needle) }
        guard !kids.isEmpty else { return nil }
        return BookmarkNode(kind: .folder, title: node.title, dateAdded: node.dateAdded, annotation: node.annotation, children: kids)
    }

    /// Drops folders whose title contains `needle`.
    private static func filterDrop(_ node: BookmarkNode, needle: String) -> BookmarkNode {
        if node.kind == .link { return node }
        if node.title.lowercased().contains(needle) {
            return BookmarkNode(kind: .folder, title: node.title, dateAdded: node.dateAdded, annotation: node.annotation, children: [])
        }
        return BookmarkNode(
            kind: .folder,
            title: node.title,
            dateAdded: node.dateAdded,
            annotation: node.annotation,
            children: node.children.map { filterDrop($0, needle: needle) }
        )
    }
}

/// Removes links whose URL already exists at the destination.
///
/// A folder that loses all of its links is dropped as well, so `--dedupe` does not leave a
/// trail of empty folders behind on repeated imports.
public enum Dedupe {
    public static func prune(_ node: BookmarkNode, existing: Set<String>) -> BookmarkNode? {
        switch node.kind {
        case .link:
            return existing.contains(node.href) ? nil : node
        case .folder:
            let kids = node.children.compactMap { prune($0, existing: existing) }
            guard !kids.isEmpty else { return nil }
            return BookmarkNode(kind: .folder, title: node.title, dateAdded: node.dateAdded, annotation: node.annotation, children: kids)
        }
    }
}
