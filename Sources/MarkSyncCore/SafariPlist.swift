import Foundation

/// Safari's real bookmark store: `~/Library/Safari/Bookmarks.plist`.
///
/// Despite Safari 17+ moving tabs and tab groups into `SafariTabs.db`, the bookmarks the user
/// sees — Favorites, the sidebar, the reading list — are still read from this property list.
/// (The `bookmarks` table in `SafariTabs.db` holds open tabs and tab groups; a `BookmarksBar`
/// row there is not what Safari displays. Verified on macOS 27 / Safari 27: items written to
/// that row never appeared, while this file's `BookmarksBar` matched the Favorites shown.)
///
/// ## Layout
///
/// ```
/// root (WebBookmarkTypeList, Title "")
/// ├── BookmarksBar            Favorites · 个人收藏
/// ├── BookmarksMenu           the legacy bookmarks menu
/// ├── com.apple.ReadingList   the reading list
/// ├── <user folders/links>    the top level of the bookmarks sidebar
/// └── WebBookmarkTypeProxy    History etc. — not bookmarks
/// ```
///
/// Folders are `WebBookmarkTypeList` with `Title` and `Children`; links are
/// `WebBookmarkTypeLeaf` with `URLString` and `URIDictionary.title`. Every item has a
/// `WebBookmarkUUID`. iCloud keeps per-item metadata under `Sync`; this class never touches
/// existing items, so that metadata is preserved, and new items carry none — the same shape
/// as a bookmark Safari has created but not yet uploaded.
public final class SafariBookmarksPlist {

    public enum PlistError: Error, CustomStringConvertible {
        case notABookmarksFile(String)
        case unknownFolder(String)

        public var description: String {
            switch self {
            case .notABookmarksFile(let path): return "\(path) is not a Safari Bookmarks.plist"
            case .unknownFolder(let uuid): return "no folder \(uuid) in Bookmarks.plist"
            }
        }
    }

    public enum Special {
        public static let bar = "BookmarksBar"
        public static let menu = "BookmarksMenu"
        public static let readingList = "com.apple.ReadingList"
    }

    static let list = "WebBookmarkTypeList"
    static let leaf = "WebBookmarkTypeLeaf"
    /// The root folder has no UUID of its own in some files; this ref stands for it.
    public static let rootRef = "root"

    public static func defaultPath(home: String? = nil) -> String {
        BrowserLocator.home(home) + "/Library/Safari/Bookmarks.plist"
    }

    private let root: NSMutableDictionary
    private let format: PropertyListSerialization.PropertyListFormat

    public init(data: Data, path: String = "Bookmarks.plist") throws {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) as? NSMutableDictionary,
              root["Children"] is NSArray || root["WebBookmarkType"] as? String == Self.list else {
            throw PlistError.notABookmarksFile(path)
        }
        self.root = root
        self.format = format
    }

    public static func load(path: String) throws -> SafariBookmarksPlist {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw BookmarkError.unreadable(path, (error as NSError).localizedDescription
                + " — grant Full Disk Access to your terminal in System Settings › Privacy & Security")
        }
        return try SafariBookmarksPlist(data: data, path: path)
    }

    private func children(_ folder: NSDictionary) -> [NSMutableDictionary] {
        ((folder["Children"] as? NSArray) ?? []).compactMap { $0 as? NSMutableDictionary }
    }

    private func type(_ item: NSDictionary) -> String? { item["WebBookmarkType"] as? String }
    private func title(_ item: NSDictionary) -> String { item["Title"] as? String ?? "" }

    private func special(_ name: String) -> NSMutableDictionary? {
        children(root).first { type($0) == Self.list && title($0) == name }
    }

    private static let specialTitles: Set<String> = [Special.bar, Special.menu, Special.readingList]

    /// Top-level items of the sidebar: root children that are not special folders or proxies.
    private var topLevelItems: [NSMutableDictionary] {
        children(root).filter { item in
            guard let t = type(item), t == Self.list || t == Self.leaf else { return false }
            return !(t == Self.list && Self.specialTitles.contains(title(item)))
        }
    }

    // MARK: - Reading

    private func node(_ item: NSDictionary) -> BookmarkNode? {
        switch type(item) {
        case Self.list:
            return BookmarkNode(kind: .folder, title: title(item), children: children(item).compactMap { node($0) })
        case Self.leaf:
            guard let url = item["URLString"] as? String, !url.isEmpty else { return nil }
            let name = (item["URIDictionary"] as? NSDictionary)?["title"] as? String
            return BookmarkNode(kind: .link, title: (name?.isEmpty == false ? name! : url), url: url)
        default:
            return nil
        }
    }

    private func nodes(_ folder: NSDictionary?) -> [BookmarkNode] {
        folder.map { children($0).compactMap { node($0) } } ?? []
    }

    /// Favorites, the sidebar, the bookmarks menu and the reading list as a tree.
    public func tree(includeReadingList: Bool = true) -> BookmarkTree {
        var roots: [BookmarkTree.RootFolder] = []
        roots.append(.init(id: "bookmark_bar", title: "Favorites", node: .folder("Favorites", children: nodes(special(Special.bar)))))
        let menu = nodes(special(Special.menu))
        if !menu.isEmpty { roots.append(.init(id: "menu", title: "Bookmarks Menu", node: .folder("Bookmarks Menu", children: menu))) }
        roots.append(.init(id: "other", title: "Bookmarks", node: .folder("Bookmarks", children: topLevelItems.compactMap { node($0) })))
        if includeReadingList {
            let list = nodes(special(Special.readingList))
            if !list.isEmpty { roots.append(.init(id: "reading_list", title: "Reading List", node: .folder("Reading List", children: list))) }
        }
        return BookmarkTree(source: "safari", roots: roots)
    }

    /// Favorites › `bar`; the sidebar's top level (plus a non-empty bookmarks menu, as a
    /// folder) › `other`.
    public func syncSource() -> SlottedBookmarks {
        SlottedBookmarks(tree(includeReadingList: false))
    }

    /// Existing folders and URLs per slot. Safari has no `mobile` slot.
    public func mergeTarget() -> [BookmarkSlot: BookmarkMerge.TargetFolder] {
        func folder(_ item: NSDictionary, ref: String) -> BookmarkMerge.TargetFolder {
            var out = BookmarkMerge.TargetFolder(ref: ref, title: title(item))
            for child in children(item) {
                if type(child) == Self.list, let uuid = child["WebBookmarkUUID"] as? String {
                    out.folders.append(folder(child, ref: uuid))
                } else if type(child) == Self.leaf, let url = child["URLString"] as? String {
                    out.urls.append(url)
                }
            }
            return out
        }
        var slots: [BookmarkSlot: BookmarkMerge.TargetFolder] = [:]
        if let bar = special(Special.bar), let uuid = bar["WebBookmarkUUID"] as? String {
            slots[.bar] = folder(bar, ref: uuid)
        }
        // `other` is the root, minus the special folders, which must never be matched by
        // title or receive sidebar items.
        var other = folder(root, ref: Self.rootRef)
        other.folders.removeAll { Self.specialTitles.contains($0.title) }
        slots[.other] = other
        return slots
    }

    // MARK: - Writing

    private func find(_ uuid: String, in folder: NSMutableDictionary) -> NSMutableDictionary? {
        for child in children(folder) where type(child) == Self.list {
            if child["WebBookmarkUUID"] as? String == uuid { return child }
            if let hit = find(uuid, in: child) { return hit }
        }
        return nil
    }

    private func folder(ref: String) -> NSMutableDictionary? {
        ref == Self.rootRef ? root : find(ref, in: root)
    }

    /// Appends `nodes` to a folder and returns the UUIDs of the items created directly in it.
    @discardableResult
    public func insert(_ nodes: [BookmarkNode], into ref: String) throws -> [String] {
        guard let parent = folder(ref: ref) else { throw PlistError.unknownFolder(ref) }
        let list = (parent["Children"] as? NSMutableArray) ?? NSMutableArray()
        parent["Children"] = list
        var created: [String] = []
        for node in nodes {
            let item = encode(node)
            list.add(item)
            created.append(item["WebBookmarkUUID"] as! String)
        }
        return created
    }

    private func encode(_ node: BookmarkNode) -> NSMutableDictionary {
        let item = NSMutableDictionary()
        item["WebBookmarkUUID"] = UUID().uuidString
        if node.kind == .folder {
            item["WebBookmarkType"] = Self.list
            item["Title"] = node.title
            item["Children"] = NSMutableArray(array: node.children.map { encode($0) })
        } else {
            item["WebBookmarkType"] = Self.leaf
            item["URLString"] = node.href
            item["URIDictionary"] = NSMutableDictionary(dictionary: ["title": node.title])
        }
        return item
    }

    /// Removes items by UUID, wherever they are. Returns how many were found.
    @discardableResult
    public func remove(uuids: Set<String>) -> Int {
        var removed = 0
        func sweep(_ folder: NSMutableDictionary) {
            guard let list = folder["Children"] as? NSMutableArray else { return }
            for index in stride(from: list.count - 1, through: 0, by: -1) {
                guard let child = list[index] as? NSMutableDictionary else { continue }
                if let uuid = child["WebBookmarkUUID"] as? String, uuids.contains(uuid) {
                    list.removeObject(at: index)
                    removed += 1
                } else if type(child) == Self.list {
                    sweep(child)
                }
            }
        }
        sweep(root)
        return removed
    }

    /// Bookmarks (links) under the given UUIDs, for undo summaries.
    public func linkCount(uuids: Set<String>) -> Int {
        var count = 0
        func visit(_ folder: NSDictionary, counting: Bool) {
            for child in children(folder) {
                let hit = counting || uuids.contains(child["WebBookmarkUUID"] as? String ?? "")
                if type(child) == Self.leaf, hit { count += 1 }
                if type(child) == Self.list { visit(child, counting: hit) }
            }
        }
        visit(root, counting: false)
        return count
    }

    /// The file contents, in the format the file was read in (normally binary).
    public func data() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
    }
}

/// Guards a read-modify-write of a file another process may also write (Safari's iCloud agent,
/// a browser): the write is refused if the file changed since it was read.
public struct FileSnapshot {
    public let path: String
    let modified: Date?
    let size: Int?

    public init(path: String) {
        self.path = path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        modified = attrs?[.modificationDate] as? Date
        size = (attrs?[.size] as? NSNumber)?.intValue
    }

    public var isUnchanged: Bool {
        let now = FileSnapshot(path: path)
        return now.modified == modified && now.size == size
    }
}
