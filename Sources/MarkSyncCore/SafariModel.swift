import Foundation

/// Errors raised while mapping Safari's bookmark store onto the generic model.
public enum SafariModelError: Error, CustomStringConvertible {
    case noSuchProfile(String)
    case noDatabase(String)

    public var description: String {
        switch self {
        case .noSuchProfile(let name):
            return "no Safari profile matching '\(name)' (run `marksync profiles` to list them)"
        case .noDatabase(let path):
            return "no Safari bookmark database at \(path)"
        }
    }
}

/// A read-only view of Safari's bookmark store.
///
/// ## Why this reads SQLite instead of the private framework
///
/// `WebBookmarkCollection` knows about `com.apple.bookmarks.OmitFromUI` and hides every folder
/// carrying it. On a stock macOS 26 install **all** profile folders live under the collection
/// root and are hidden that way, so `-listWithID:` (and even `...includeHidden:YES`) reports a
/// root with two children — while the database actually holds several profiles full of
/// bookmarks. Reading the database directly is therefore both simpler and strictly more
/// complete. The framework is still the right tool for *writing* (see ``SafariBridge``), because
/// only it maintains `dav_generation`, sync metadata and child counters.
///
/// ## Store layout (verified against macOS 26 / Safari 26)
///
/// | what the user sees  | how it is stored                                                        |
/// |---------------------|-------------------------------------------------------------------------|
/// | Bookmarks bar       | folder with `special_id = 1`                                             |
/// | Bookmarks menu      | `special_id = 2` (legacy, usually absent)                                |
/// | Reading list        | `special_id = 3`                                                         |
/// | a profile           | hidden root folder (`parent is null`) holding a `com.apple.Bookmark`      |
/// |                     | › `DateAdded` extra-attribute blob, plus a hidden `Private` sibling       |
/// | Tab groups / pinned | hidden root folders `pinned`, `privatePinned`, `recentlyClosed`          |
public final class SafariModel {

    public struct ProfileInfo: Equatable, Sendable {
        /// Folder id of the profile's `Local` folder — where its bookmarks live.
        public var localFolderID: Int
        public var privateFolderID: Int?
        public var title: String
        public var dateAdded: Date?
        public var linkCount: Int
        public var folderCount: Int
        public var isActive: Bool

        public var id: Int { localFolderID }
    }

    public struct Destination {
        public var parentID: Int
        public var description: String
        public init(parentID: Int, description: String) {
            self.parentID = parentID
            self.description = description
        }
    }

    /// One row of the `bookmarks` table, reduced to the fields the tools need.
    public struct Row {
        public var id: Int
        public var parent: Int?
        public var specialID: Int
        public var isFolder: Bool
        public var subtype: Int
        public var hidden: Bool
        public var orderIndex: Int
        public var title: String
        public var url: String?
        public var isDeleted: Bool
        public var dateAdded: Date?
        public var annotation: String?
    }

    public let databasePath: String
    private let rows: [Int: Row]
    private let childrenOf: [Int: [Int]]
    private let rootIDs: [Int]

    // MARK: - Construction

    public init(databasePath: String) throws {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw SafariModelError.noDatabase(databasePath)
        }
        self.databasePath = databasePath
        // Ordering in SQL keeps sibling order stable without sorting again here.
        // `extra_attributes` is a BLOB, so it must be read as hex — `sqlite3_column_text`
        // truncates at the first NUL byte otherwise.
        let ordered = SQLite.rows(path: databasePath, sql: """
            select id, parent, special_id, type, subtype, hidden, order_index, title, url,
                   deleted, num_children, hex(extra_attributes)
            from bookmarks order by parent, order_index, id
            """)
        var rows: [Int: Row] = [:]
        var childrenOf: [Int: [Int]] = [:]
        var roots: [Int] = []
        for r in ordered {
            guard r.count >= 12, let id = r[0].flatMap(Int.init) else { continue }
            let parent = r[1].flatMap(Int.init)
            let row = Row(
                id: id,
                parent: parent,
                specialID: r[2].flatMap(Int.init) ?? 0,
                isFolder: (r[3].flatMap(Int.init) ?? 0) == 1,
                subtype: r[4].flatMap(Int.init) ?? 0,
                hidden: (r[5].flatMap(Int.init) ?? 0) != 0,
                orderIndex: r[6].flatMap(Int.init) ?? 0,
                title: r[7] ?? "",
                url: (r[8].flatMap { $0.isEmpty ? nil : $0 }),
                isDeleted: (r[9].flatMap(Int.init) ?? 0) != 0,
                dateAdded: Self.dateAdded(fromExtraAttributesHex: r[11]),
                annotation: Self.annotation(fromExtraAttributesHex: r[11])
            )
            rows[id] = row
            if let parent { childrenOf[parent, default: []].append(id) } else { roots.append(id) }
        }
        self.rows = rows
        self.childrenOf = childrenOf
        self.rootIDs = roots
    }

    public convenience init(handle: SafariBridge.Handle) throws {
        try self.init(databasePath: handle.databasePath)
    }

    // MARK: - Blob decoding

    /// `extra_attributes` is an `NSKeyedArchiver` property list holding, among other things,
    /// `com.apple.Bookmark` › `DateAdded` and `com.apple.bookmarks.OmitFromUI`.
    static func extraAttributes(fromHex hex: String?) -> [String: Any] {
        guard let hex, !hex.isEmpty, let data = Data(hexString: hex) else { return [:] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return [:] }
        return plist as? [String: Any] ?? [:]
    }

    public static func dateAdded(fromExtraAttributesHex hex: String?) -> Date? {
        let attrs = extraAttributes(fromHex: hex)
        guard let bookmark = attrs["com.apple.Bookmark"] as? [String: Any] else { return nil }
        if let d = bookmark["DateAdded"] as? Date { return d }
        if let n = bookmark["DateAdded"] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }

    public static func annotation(fromExtraAttributesHex hex: String?) -> String? {
        let attrs = extraAttributes(fromHex: hex)
        guard let bookmark = attrs["com.apple.Bookmark"] as? [String: Any] else { return nil }
        return (bookmark["Description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func omitsFromUI(_ hex: String?) -> Bool {
        extraAttributes(fromHex: hex)["com.apple.bookmarks.OmitFromUI"] as? Bool ?? false
    }

    // MARK: - Raw access

    public func row(_ id: Int) -> Row? { rows[id] }
    public func children(_ id: Int, includeDeleted: Bool = false) -> [Row] {
        (childrenOf[id] ?? []).compactMap { rows[$0] }.filter { includeDeleted || !$0.isDeleted }
    }
    public var allRoots: [Row] { rootIDs.compactMap { rows[$0] } }

    /// Every folder that sits at the top of the store: `parent is null` (profiles, system
    /// folders) or a direct child of the collection root (bookmarks bar, reading list).
    public var rootLevelFolders: [Row] {
        let top = Set(rootIDs + (childrenOf[0] ?? []))
        return rows.values.filter { top.contains($0.id) && $0.isFolder && !$0.isDeleted }
            .sorted { $0.id < $1.id }
    }

    public func subtreeLinkCount(_ id: Int) -> Int {
        var n = 0
        for child in children(id) {
            if child.isFolder { n += subtreeLinkCount(child.id) } else { n += 1 }
        }
        return n
    }

    public func subtreeFolderCount(_ id: Int) -> Int {
        var n = 0
        for child in children(id) {
            if child.isFolder { n += 1; n += subtreeFolderCount(child.id) }
        }
        return n
    }

    // MARK: - Special folders

    /// Titles the framework itself uses to resolve special folders.
    ///
    /// `- _databaseTitleForSpecialID:` maps 1 › `BookmarksBar`, 2 › `BookmarksMenu`,
    /// 3 › `com.apple.ReadingList`, 4 › `com.apple.WebFilterWhiteList`,
    /// 5 › `com.apple.FrequentlyVisitedSites`, 6 › `Recovered`. The `special_id` *column* is
    /// usually 0 — only folders the framework has already materialised (such as `Recovered`)
    /// carry it — so title matching is the reliable path, with the column as a fallback.
    public enum SpecialTitle {
        public static let bookmarksBar = "BookmarksBar"
        public static let bookmarksMenu = "BookmarksMenu"
        public static let readingList = "com.apple.ReadingList"
        public static let webFilterWhiteList = "com.apple.WebFilterWhiteList"
        public static let frequentlyVisited = "com.apple.FrequentlyVisitedSites"
        public static let recovered = "Recovered"
    }

    public func folder(specialID special: Int, title: String) -> Row? {
        if let byColumn = rootLevelFolders.first(where: { $0.specialID == special && $0.isFolder }) { return byColumn }
        return rootLevelFolders.first { $0.isFolder && $0.title == title }
    }

    public var bookmarksBar: Row? { folder(specialID: 1, title: SpecialTitle.bookmarksBar) }
    public var bookmarksMenu: Row? { folder(specialID: 2, title: SpecialTitle.bookmarksMenu) }
    public var readingList: Row? { folder(specialID: 3, title: SpecialTitle.readingList) }
    public var readingListID: Int? { readingList?.id }
    public var recovered: Row? { folder(specialID: 6, title: SpecialTitle.recovered) }

    /// Pre-profile Safari kept every bookmark in one `subtype = 2` folder.
    public var legacyContentFolder: Row? {
        allRoots.first { $0.isFolder && $0.subtype == SafariBridge.libriFolderSubtype }
    }

    private static let nonProfileRootTitles: Set<String> = [
        "pinned", "privatePinned", "recentlyClosed", "Private",
        SpecialTitle.bookmarksBar, SpecialTitle.bookmarksMenu, SpecialTitle.readingList,
        SpecialTitle.webFilterWhiteList, SpecialTitle.frequentlyVisited, SpecialTitle.recovered,
    ]

    /// Profile folders, in creation order.
    ///
    /// A profile is a root folder (usually `parent is null`) that is hidden, holds real
    /// bookmarks, and carries a `com.apple.Bookmark` › `DateAdded` extra-attribute blob. Its
    /// matching `Private` folder is created at the same instant — but the two timestamps differ
    /// by a few microseconds, so they are paired with a tolerance rather than equality.
    public var profiles: [ProfileInfo] {
        let candidates = rootLevelFolders.filter {
            $0.hidden && $0.subtype == 0 && $0.specialID == 0
                && !Self.nonProfileRootTitles.contains($0.title)
                && $0.dateAdded != nil
        }
        let privateRoots = rootLevelFolders.filter { $0.title == "Private" && $0.dateAdded != nil }
        let identifier = Self.activeProfileIdentifier(home: nil)
        let infos = candidates.enumerated().map { index, root -> ProfileInfo in
            let sibling = privateRoots
                .filter { $0.id != root.id && $0.dateAdded.map { abs($0.timeIntervalSince(root.dateAdded ?? .distantPast)) < 5 } ?? false }
                .min { abs(($0.dateAdded ?? .distantPast).timeIntervalSince(root.dateAdded ?? .distantPast)) < abs(($1.dateAdded ?? .distantPast).timeIntervalSince(root.dateAdded ?? .distantPast)) }
            return ProfileInfo(
                localFolderID: root.id,
                privateFolderID: sibling?.id,
                title: Self.displayName(forFolderTitle: root.title, index: index, identifier: identifier),
                dateAdded: root.dateAdded,
                linkCount: subtreeLinkCount(root.id),
                folderCount: subtreeFolderCount(root.id),
                isActive: false
            )
        }
        // A machine that has recreated its Safari container can hold several profile folders
        // that all resolve to the same display name; make them distinguishable.
        var seen: [String: Int] = [:]
        return infos.map { info in
            seen[info.title, default: 0] += 1
            guard seen[info.title]! > 1 || infos.filter({ $0.title == info.title }).count > 1 else { return info }
            var copy = info
            copy.title = "\(info.title) (#\(info.localFolderID))"
            return copy
        }
    }

    /// Every URL reachable under `id`, used by `--dedupe`.
    public func existingURLs(under id: Int) -> Set<String> {
        var out: Set<String> = []
        func visit(_ folder: Int) {
            for child in children(folder) {
                if child.isFolder { visit(child.id) }
                else if let url = child.url { out.insert(url) }
            }
        }
        visit(id)
        return out
    }

    /// The folder titles Safari writes for profile containers are placeholders, not names.
    private static let profilePlaceholderTitles: Set<String> = ["Local", "Private", ""]

    static func displayName(forFolderTitle title: String, index: Int, identifier: String?) -> String {
        if !profilePlaceholderTitles.contains(title) { return title }
        if let identifier, !identifier.isEmpty {
            if identifier == "DefaultProfile" { return "Default" }
            if identifier.hasSuffix("Profile") { return String(identifier.dropLast("Profile".count)) }
            return identifier
        }
        return index == 0 ? "Default" : "Profile \(index + 1)"
    }

    /// `SafariProfilesLastActiveProfileUUIDString` from Safari's preferences is the only place
    /// the profile identifier is stored outside the bookmark rows.
    public static func activeProfileIdentifier(home: String? = nil) -> String? {
        let base = home ?? SafariBridge.realHomeDirectory()
        let path = base + "/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist["SafariProfilesLastActiveProfileUUIDString"] as? String
    }

    /// The profile the frontmost window belongs to. `windows.local_tab_group_id` points at the
    /// profile's `Local` folder, so the newest window wins ties.
    public func activeProfileID() -> Int? {
        let ids = SQLite.integers(
            path: databasePath,
            sql: "select local_tab_group_id from windows order by id desc"
        )
        let known = Set(profiles.map(\.localFolderID))
        for id in ids where known.contains(id) { return id }
        return nil
    }

    public func profile(named needle: String) -> ProfileInfo? {
        let lower = needle.lowercased()
        let all = profiles
        if let id = Int(needle), let m = all.first(where: { $0.localFolderID == id }) { return m }
        return all.first { $0.title.lowercased() == lower }
            ?? all.first { $0.title.lowercased().contains(lower) }
    }

    /// Resolves where an import should land.
    public func destination(profileNamed name: String?) throws -> Destination? {
        if let name {
            guard let p = profile(named: name) else { throw SafariModelError.noSuchProfile(name) }
            return Destination(parentID: p.localFolderID, description: "profile '\(p.title)' (folder #\(p.localFolderID))")
        }
        if let active = activeProfileID(), let p = profiles.first(where: { $0.localFolderID == active }) {
            return Destination(parentID: p.localFolderID, description: "profile '\(p.title)' (folder #\(p.localFolderID))")
        }
        if let p = profiles.first {
            return Destination(parentID: p.localFolderID, description: "profile '\(p.title)' (folder #\(p.localFolderID))")
        }
        if let bar = bookmarksBar {
            return Destination(parentID: bar.id, description: "bookmarks bar (folder #\(bar.id))")
        }
        if let legacy = legacyContentFolder {
            return Destination(parentID: legacy.id, description: "Safari bookmarks folder (folder #\(legacy.id))")
        }
        return nil
    }

    // MARK: - Tree building

    public func tree(
        profile: String? = nil,
        includeHidden: Bool = false,
        includeReadingList: Bool = true
    ) throws -> BookmarkTree {
        var roots: [BookmarkTree.RootFolder] = []

        if let profile {
            guard let p = self.profile(named: profile) else { throw SafariModelError.noSuchProfile(profile) }
            roots.append(.init(
                id: "profile-\(p.localFolderID)",
                title: p.title,
                node: .folder(p.title, children: nodes(in: p.localFolderID, includeHidden: includeHidden))
            ))
        } else {
            if let bar = bookmarksBar {
                let children = nodes(in: bar.id, includeHidden: includeHidden)
                if !children.isEmpty || includeHidden {
                    roots.append(.init(id: "bookmark_bar", title: "Bookmarks Bar", node: .folder("Bookmarks Bar", children: children)))
                }
            }
            for p in profiles {
                let children = nodes(in: p.localFolderID, includeHidden: includeHidden)
                roots.append(.init(id: "profile-\(p.localFolderID)", title: p.title, node: .folder(p.title, children: children)))
            }
            if roots.isEmpty, let legacy = legacyContentFolder {
                let children = nodes(in: legacy.id, includeHidden: includeHidden)
                roots.append(.init(id: "bookmark_bar", title: "Safari", node: .folder("Safari", children: children)))
            }
            if includeHidden {
                // Tab-group folders and anything else the user has tucked away still hold real
                // bookmarks, so export them instead of dropping them silently.
                let accounted = Set(
                    [bookmarksBar?.id, bookmarksMenu?.id, readingListID, legacyContentFolder?.id].compactMap { $0 }
                    + profiles.map(\.localFolderID)
                    + profiles.compactMap(\.privateFolderID)
                )
                for root in allRoots where root.isFolder && !accounted.contains(root.id)
                    && !Self.nonProfileRootTitles.contains(root.title) {
                    let children = nodes(in: root.id, includeHidden: true)
                    if !children.isEmpty {
                        roots.append(.init(id: "extra-\(root.id)", title: root.title, node: .folder(root.title, children: children)))
                    }
                }
            }
        }

        if includeReadingList, let list = readingList {
            var items = nodes(in: list.id, includeHidden: true)
            // Reading list entries frequently have an empty title; show the URL instead.
            for i in items.indices where items[i].title.isEmpty {
                items[i].title = items[i].url ?? ""
            }
            if !items.isEmpty {
                roots.append(.init(id: "reading_list", title: "Reading List", node: .folder("Reading List", children: items)))
            }
        }
        return BookmarkTree(source: "safari", roots: roots)
    }

    /// Recursively converts a Safari folder into generic nodes.
    public func nodes(in folderID: Int, includeHidden: Bool) -> [BookmarkNode] {
        children(folderID).compactMap { child -> BookmarkNode? in
            if child.hidden && !includeHidden { return nil }
            if child.isFolder {
                // Only real folders and the legacy container hold user bookmarks; other
                // subtypes are session state for tab groups.
                guard child.subtype == 0 || child.subtype == SafariBridge.libriFolderSubtype else { return nil }
                return BookmarkNode(
                    kind: .folder,
                    title: child.title,
                    dateAdded: child.dateAdded,
                    annotation: child.annotation,
                    children: nodes(in: child.id, includeHidden: includeHidden)
                )
            }
            guard let address = child.url, !address.isEmpty else { return nil }
            return BookmarkNode(
                kind: .link,
                title: child.title,
                url: address,
                dateAdded: child.dateAdded,
                annotation: child.annotation
            )
        }
    }

    /// Flat row dump used by `marksync inspect db`.
    public func rowDump() -> [String] {
        var out: [String] = []
        out.append("id     parent special type sub hidden kids title / url")
        func visit(_ id: Int, depth: Int) {
            for child in children(id) {
                let pad = String(repeating: "  ", count: depth)
                let text = child.url ?? child.title
                out.append(String(
                    format: "%-6d %-6@ %-7d %-4@ %-3d %-6@ %-4@ %@%@",
                    child.id,
                    (child.parent.map(String.init) ?? "-") as NSString,
                    child.specialID,
                    (child.isFolder ? "dir" : "url") as NSString,
                    child.subtype,
                    (child.hidden ? "yes" : "no") as NSString,
                    String(children(child.id).count) as NSString,
                    pad as NSString,
                    text as NSString
                ))
                if child.isFolder { visit(child.id, depth: depth + 1) }
            }
        }
        visit(0, depth: 0)
        for root in allRoots where root.id != 0 {
            let marker = root.parent == nil ? "(root) " : ""
            out.append("root   #\(root.id) \(marker)special=\(root.specialID) '\(root.title)' -> \(children(root.id).count) children")
        }
        return out
    }
}

extension Data {
    public init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
