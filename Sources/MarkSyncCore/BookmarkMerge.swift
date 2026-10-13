import Foundation

/// The places every browser has, under different names.
///
/// | slot     | Safari                         | Chrome / Edge                     | Firefox            |
/// |----------|--------------------------------|-----------------------------------|--------------------|
/// | `bar`    | Favorites (`BookmarksBar`)     | Bookmarks bar / 收藏夹栏          | Bookmarks Toolbar  |
/// | `other`  | the profile's bookmarks        | Other bookmarks / 其他收藏夹      | Other Bookmarks    |
/// | `mobile` | —                              | Mobile bookmarks / 移动收藏夹     | Mobile Bookmarks   |
///
/// Syncing maps slot to slot, so the bookmarks bar of one browser lands on the bookmarks bar of
/// the other instead of inside an "Imported" folder.
public enum BookmarkSlot: String, CaseIterable, Sendable {
    case bar
    case other
    case mobile

    /// The slot a `BookmarkTree` root id belongs to. Roots with no slot of their own
    /// (`menu`, Safari profiles, …) are kept as folders inside `other`.
    public static func slot(forRootID id: String) -> BookmarkSlot? {
        switch id {
        case "bookmark_bar": return .bar
        case "other", "unfiled": return .other
        case "synced", "mobile": return .mobile
        default: return nil
        }
    }
}

/// A tree's contents, sorted into slots.
public struct SlottedBookmarks: Sendable {
    public var nodes: [BookmarkSlot: [BookmarkNode]] = [:]
    /// The source's own title for each slot, used when a slot has to become a folder.
    public var titles: [BookmarkSlot: String] = [:]

    public init(nodes: [BookmarkSlot: [BookmarkNode]] = [:], titles: [BookmarkSlot: String] = [:]) {
        self.nodes = nodes
        self.titles = titles
    }

    /// Sorts a tree into slots. The reading list is not a bookmark folder in Chromium and is
    /// left out; any other unknown root becomes a folder inside `other`.
    public init(_ tree: BookmarkTree, includeReadingList: Bool = false) {
        for root in tree.roots {
            if root.id == "reading_list" && !includeReadingList { continue }
            if let slot = BookmarkSlot.slot(forRootID: root.id) {
                nodes[slot, default: []].append(contentsOf: root.node.children)
                if titles[slot] == nil { titles[slot] = root.title }
            } else {
                var folder = root.node
                folder.title = root.title
                nodes[.other, default: []].append(folder)
            }
        }
    }

    public func children(_ slot: BookmarkSlot) -> [BookmarkNode] { nodes[slot] ?? [] }

    public var linkCount: Int {
        nodes.values.reduce(0) { sum, list in sum + list.reduce(0) { $0 + $1.linkCount } }
    }

    /// A `BookmarkTree` view, for printing.
    public var tree: BookmarkTree {
        let ids: [BookmarkSlot: String] = [.bar: "bookmark_bar", .other: "other", .mobile: "synced"]
        let roots = BookmarkSlot.allCases.compactMap { slot -> BookmarkTree.RootFolder? in
            let kids = children(slot)
            guard !kids.isEmpty else { return nil }
            let title = titles[slot] ?? BookmarkMerge.defaultTitle(slot)
            return .init(id: ids[slot]!, title: title, node: .folder(title, children: kids))
        }
        return BookmarkTree(source: "slots", roots: roots)
    }
}

/// Additive, structure-preserving merge of one browser's bookmarks into another's.
///
/// The merge never deletes or moves anything in the target. Folders are matched by title at
/// the same position; a link is skipped when its URL already exists anywhere in the same slot
/// of the target. Running the same sync twice therefore adds nothing the second time.
public enum BookmarkMerge {

    /// An existing folder in the target store. `ref` is the store's own id for it — a row id
    /// for Safari, a node id for Chromium — and is handed back in ``Insertion/parentRef``.
    public struct TargetFolder: Sendable {
        public var ref: String
        public var title: String
        public var folders: [TargetFolder]
        public var urls: [String]

        public init(ref: String, title: String, folders: [TargetFolder] = [], urls: [String] = []) {
            self.ref = ref
            self.title = title
            self.folders = folders
            self.urls = urls
        }

        var allURLs: [String] { urls + folders.flatMap(\.allURLs) }
    }

    /// New nodes to append to one existing target folder.
    public struct Insertion: Sendable {
        public var parentRef: String
        /// Human-readable location, e.g. `bar › Dev`.
        public var path: String
        public var nodes: [BookmarkNode]
    }

    public struct Plan: Sendable {
        public var insertions: [Insertion] = []
        /// Links skipped because the target already has them.
        public var skipped = 0
        /// Source slots that had no counterpart and were folded into `other` as a folder.
        public var folded: [BookmarkSlot] = []

        public var linkCount: Int { insertions.reduce(0) { $0 + $1.nodes.reduce(0) { $0 + $1.linkCount } } }
        public var folderCount: Int { insertions.reduce(0) { $0 + $1.nodes.reduce(0) { $0 + $1.folderCount } } }
        public var isEmpty: Bool { insertions.isEmpty }
    }

    public static func defaultTitle(_ slot: BookmarkSlot) -> String {
        switch slot {
        case .bar: return "Bookmarks bar"
        case .other: return "Other bookmarks"
        case .mobile: return "Mobile bookmarks"
        }
    }

    /// Plans the merge of `source` into `target`.
    ///
    /// A source slot the target does not have (Safari has no `mobile`) is merged into the
    /// target's `other` slot as a folder named after the source slot, so re-running finds
    /// that folder again instead of creating a second one.
    public static func plan(source: SlottedBookmarks, target: [BookmarkSlot: TargetFolder]) -> Plan {
        var plan = Plan()
        var work: [BookmarkSlot: [BookmarkNode]] = [:]
        for slot in BookmarkSlot.allCases {
            let kids = source.children(slot)
            guard !kids.isEmpty else { continue }
            if target[slot] != nil {
                work[slot, default: []].append(contentsOf: kids)
            } else {
                let title = source.titles[slot] ?? defaultTitle(slot)
                work[.other, default: []].append(.folder(title, children: kids))
                plan.folded.append(slot)
            }
        }

        for slot in BookmarkSlot.allCases {
            guard let nodes = work[slot], let folder = target[slot] else { continue }
            var seen = Set(folder.allURLs.map(normalize))
            merge(nodes, into: folder, path: slot.rawValue, seen: &seen, plan: &plan)
        }
        return plan
    }

    private static func merge(_ nodes: [BookmarkNode], into folder: TargetFolder, path: String, seen: inout Set<String>, plan: inout Plan) {
        var pending: [BookmarkNode] = []
        for node in nodes {
            switch node.kind {
            case .link:
                if seen.insert(normalize(node.href)).inserted {
                    pending.append(node)
                } else {
                    plan.skipped += 1
                }
            case .folder:
                if let match = folder.folders.first(where: { $0.title == node.title }) {
                    merge(node.children, into: match, path: "\(path) › \(node.title)", seen: &seen, plan: &plan)
                } else if let pruned = prune(node, seen: &seen, skipped: &plan.skipped) {
                    pending.append(pruned)
                }
            }
        }
        if !pending.isEmpty {
            plan.insertions.append(Insertion(parentRef: folder.ref, path: path, nodes: pending))
        }
    }

    /// Drops already-present links from a brand-new folder, and the folder itself if that
    /// leaves it empty. Empty folders in the source are kept: the user made them on purpose.
    private static func prune(_ node: BookmarkNode, seen: inout Set<String>, skipped: inout Int) -> BookmarkNode? {
        guard node.kind == .folder else {
            if seen.insert(normalize(node.href)).inserted { return node }
            skipped += 1
            return nil
        }
        if node.children.isEmpty { return node }
        var copy = node
        copy.children = node.children.compactMap { prune($0, seen: &seen, skipped: &skipped) }
        return copy.children.isEmpty ? nil : copy
    }

    /// URL identity for duplicate detection: case-insensitive scheme and host, and a bare
    /// trailing `/` ignored, so `HTTPS://Example.com` and `https://example.com/` match.
    public static func normalize(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), parts.host != nil else { return trimmed }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.path == "/" { parts.path = "" }
        return parts.string ?? trimmed
    }
}
