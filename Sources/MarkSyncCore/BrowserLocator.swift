import Foundation

/// Detects the format of a file we are asked to read.
public enum BookmarkFormat: String, Sendable {
    case netscapeHTML = "html"
    case chromiumJSON = "chromium"
    case treeJSON = "json"
    case firefoxSQLite = "firefox"

    public static func detect(_ data: Data, path: String) -> BookmarkFormat? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let head = String(data: data.prefix(4096), encoding: .utf8)?.lowercased() ?? ""
        // Firefox keeps bookmarks inside places.sqlite.
        if data.starts(with: Array("SQLite format 3".utf8)) {
            if name.hasSuffix(".sqlite") || name.hasSuffix(".db") { return .firefoxSQLite }
        }
        if name.hasSuffix(".html") || name.hasSuffix(".htm") { return .netscapeHTML }
        if head.contains("netscape-bookmark-file") { return .netscapeHTML }
        if head.contains("<!doctype html") && head.contains("<dl") && head.contains("<dt>") { return .netscapeHTML }
        if let first = head.first(where: { !$0.isWhitespace }) {
            if first == "{" {
                if head.contains("\"roots\"") && head.contains("\"bookmark_bar\"") { return .chromiumJSON }
                if head.contains("\"checksum\"") || head.contains("\"date_added\"") { return .chromiumJSON }
                if head.contains("\"children\"") || head.contains("\"folders\"") { return .treeJSON }
                // Chromium bookmarks always carry a "roots" key.
                if head.contains("\"roots\"") { return .chromiumJSON }
                return .treeJSON
            }
            if first == "b" && head.contains("bplist00") { return nil }
            if head.hasPrefix("<?xml") { return nil }
        }
        return nil
    }
}

/// Reads a bookmark file of any supported format.
public enum BookmarkFile {

    public struct Info {
        public var path: String
        public var format: BookmarkFormat
        public var label: String
    }

    public static func read(path: String, explicitFormat: String?) throws -> BookmarkTree {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BookmarkError.unreadable(expanded, error.localizedDescription)
        }
        let format: BookmarkFormat
        if let explicitFormat, explicitFormat.lowercased() != "auto" {
            switch explicitFormat.lowercased() {
            case "html", "netscape": format = .netscapeHTML
            case "chromium", "chrome", "edge", "brave", "opera": format = .chromiumJSON
            case "json", "tree": format = .treeJSON
            case "firefox", "places", "sqlite": format = .firefoxSQLite
            default:
                throw BookmarkError.unsupportedFormat(explicitFormat)
            }
        } else if let detected = BookmarkFormat.detect(data, path: expanded) {
            format = detected
        } else {
            throw BookmarkError.notABookmarkFile(expanded)
        }

        switch format {
        case .netscapeHTML:
            guard let text = decodeText(data) else {
                throw BookmarkError.unreadable(expanded, "not valid UTF-8 or Latin-1 text")
            }
            return try NetscapeHTML.parse(text)
        case .chromiumJSON:
            return try ChromiumBookmarks.parse(data)
        case .treeJSON:
            return try JSONOutput.decodeTree(data)
        case .firefoxSQLite:
            return try FirefoxBookmarks.parse(path: expanded)
        }
    }

    /// Bookmark exports are frequently declared as Latin-1 or UTF-8; try both, never fail on encoding.
    static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(data: data, encoding: .utf16)
    }
}

/// Locates the on-disk bookmark files of the browsers installed on this Mac.
public enum BrowserLocator {

    public struct Installed {
        public var name: String
        public var profiles: [BookmarkFile.Info]
    }

    public struct Candidate {
        public var name: String
        /// Path under `~/Library/Application Support`.
        public var applicationSupportPath: String
        /// True when the bookmark file sits directly in `applicationSupportPath` (Opera).
        public var isFlat: Bool
        /// Used to refuse writing a bookmark file while the browser has it open.
        public var bundleIdentifier: String
        /// False for browsers whose `Bookmarks` file is not what the user sees (Arc's sidebar
        /// lives elsewhere), so syncing *into* them would look like it did nothing.
        public var isWritable: Bool

        public init(name: String, applicationSupportPath: String, isFlat: Bool = false, bundleIdentifier: String, isWritable: Bool = true) {
            self.name = name
            self.applicationSupportPath = applicationSupportPath
            self.isFlat = isFlat
            self.bundleIdentifier = bundleIdentifier
            self.isWritable = isWritable
        }
    }

    /// Chromium-family browsers keep bookmarks in `<profile>/Bookmarks`.
    ///
    /// Profiles signed into a Google account may instead (or additionally) use
    /// `AccountBookmarks`, which holds the server-side bookmarks Chrome has downloaded. Both
    /// names are probed, and profile directories are *scanned* rather than hard-coded — a real
    /// install routinely has `Profile 11` or `Profile 42`, which a fixed list would miss.
    public static let chromiumBrowsers: [Candidate] = [
        .init(name: "chrome", applicationSupportPath: "Google/Chrome", bundleIdentifier: "com.google.Chrome"),
        .init(name: "edge", applicationSupportPath: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac"),
        .init(name: "brave", applicationSupportPath: "BraveSoftware/Brave-Browser", bundleIdentifier: "com.brave.Browser"),
        .init(name: "chromium", applicationSupportPath: "Chromium", bundleIdentifier: "org.chromium.Chromium"),
        .init(name: "vivaldi", applicationSupportPath: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi"),
        .init(name: "arc", applicationSupportPath: "Arc/User Data", bundleIdentifier: "company.thebrowser.Browser", isWritable: false),
        .init(name: "opera", applicationSupportPath: "com.operasoftware.Opera", isFlat: true, bundleIdentifier: "com.operasoftware.Opera"),
    ]

    static let bookmarkFileNames = ["Bookmarks", "AccountBookmarks"]

    /// Directory names under an Application Support root that are never user profiles.
    static let nonProfileDirectories: Set<String> = [
        "System Profile", "Guest Profile", "Crashpad", "ShaderCache", "GrShaderCache",
        "GraphiteDawnCache", "NativeMessagingHosts", "Webstore Downloads", "Safe Browsing",
    ]

    /// How many links a Chromium bookmark file contains, or nil if it cannot be read.
    public static func chromiumLinkCount(path: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let tree = try? ChromiumBookmarks.parse(data) else { return nil }
        return tree.linkCount
    }

    /// Picks the bookmark file for one profile directory.
    ///
    /// `Bookmarks` wins when it actually holds something; otherwise `AccountBookmarks` is used
    /// (a profile using account bookmarks has no local `Bookmarks` file at all, and a profile
    /// that has one may still have an empty one). Returning both would double-import every
    /// synced bookmark, so exactly one file per profile is chosen.
    static func chooseBookmarkFile(in directory: String, label: String) -> BookmarkFile.Info? {
        var local: (path: String, count: Int)?
        var account: (path: String, count: Int)?
        for name in bookmarkFileNames {
            let path = "\(directory)/\(name)"
            guard FileManager.default.fileExists(atPath: path), let count = chromiumLinkCount(path: path) else { continue }
            if name == "Bookmarks" { local = (path, count) } else { account = (path, count) }
        }
        if let local, local.count > 0 {
            return .init(path: local.path, format: .chromiumJSON, label: label)
        }
        if let account, account.count > 0 {
            return .init(path: account.path, format: .chromiumJSON, label: "\(label) (account)")
        }
        // Nothing usable: still report the local file so the caller can say "0 bookmarks".
        if let local { return .init(path: local.path, format: .chromiumJSON, label: label) }
        return nil
    }

    /// The bookmark files for one browser name, or every known browser for `all`.
    public static func bookmarkFiles(forBrowser name: String, home homeOverride: String? = nil) throws -> [BookmarkFile.Info] {
        let wanted = name.lowercased()
        let base = home(homeOverride) + "/Library/Application Support"
        var candidates = chromiumBrowsers
        if wanted != "all" && wanted != "auto" {
            candidates = chromiumBrowsers.filter { $0.name == wanted }
            let known = chromiumBrowsers.map(\.name) + ["firefox"]
            if candidates.isEmpty && !known.contains(wanted) {
                throw BookmarkError.unknownBrowser(name, known: known)
            }
        }

        var out: [BookmarkFile.Info] = []
        for candidate in candidates {
            let root = "\(base)/\(candidate.applicationSupportPath)"
            // Some builds keep the file directly in the Application Support directory.
            if let direct = chooseBookmarkFile(in: root, label: candidate.name) { out.append(direct) }
            guard !candidate.isFlat else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where !nonProfileDirectories.contains(entry) {
                var isDirectory: ObjCBool = false
                let path = "\(root)/\(entry)"
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if let info = chooseBookmarkFile(in: path, label: "\(candidate.name) \(entry)") {
                    out.append(info)
                }
            }
        }

        if wanted == "firefox" || wanted == "all" || wanted == "auto" {
            out.append(contentsOf: firefoxBookmarkFiles(home: homeOverride))
        }

        return out
    }

    /// Resolves `~` against the real account home, not the sandbox container.
    /// `MARKSYNC_HOME` redirects it, so a sync can be rehearsed against a scratch copy.
    public static func home(_ override: String? = nil) -> String {
        override ?? ProcessInfo.processInfo.environment["MARKSYNC_HOME"] ?? SafariBridge.realHomeDirectory()
    }

    /// Firefox keeps bookmarks in SQLite, one `places.sqlite` per profile.
    public static func firefoxBookmarkFiles(home homeOverride: String? = nil) -> [BookmarkFile.Info] {
        let base = home(homeOverride) + "/Library/Application Support/Firefox/Profiles"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        var out: [BookmarkFile.Info] = []
        for entry in entries.sorted() {
            let db = "\(base)/\(entry)/places.sqlite"
            guard FileManager.default.fileExists(atPath: db) else { continue }
            out.append(.init(path: db, format: .firefoxSQLite, label: "firefox \(entry)"))
        }
        return out
    }

    /// Every browser/profile that has a readable bookmark file on this machine.
    public static func installed(home homeOverride: String? = nil) -> [Installed] {
        var out: [Installed] = []
        for candidate in chromiumBrowsers {
            let files = (try? bookmarkFiles(forBrowser: candidate.name, home: homeOverride)) ?? []
            if !files.isEmpty { out.append(.init(name: candidate.name, profiles: files)) }
        }
        let ff = firefoxBookmarkFiles(home: homeOverride)
        if !ff.isEmpty { out.append(.init(name: "firefox", profiles: ff)) }
        return out
    }
}

/// Reads Firefox's `places.sqlite` directly.
///
/// `moz_bookmarks` holds the tree (`type` 2 = folder, 1 = bookmark) and
/// `moz_places` the URLs; `dateAdded` is microseconds since the Unix epoch.
public enum FirefoxBookmarks {

    public static func parse(path: String) throws -> BookmarkTree {
        let folders = SQLite.rows(path: path, sql: """
            select b.id, b.parent, b.title, b.type, b.dateAdded, p.url
            from moz_bookmarks b
            left join moz_places p on p.id = b.fk
            """)
        guard !folders.isEmpty else {
            throw BookmarkError.notABookmarkFile("\(path) (no moz_bookmarks table)")
        }
        struct Node { var id: Int; var parent: Int; var title: String; var isFolder: Bool; var date: Date?; var url: String? }
        var nodes: [Int: Node] = [:]
        var childrenOf: [Int: [Int]] = [:]
        for row in folders {
            guard let id = row[0].flatMap(Int.init),
                  let parent = row[1].flatMap(Int.init) else { continue }
            let title = row[2] ?? ""
            let type = row[3].flatMap(Int.init) ?? 1
            let date = row[4].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000_000) }
            let url = row[5]
            nodes[id] = Node(id: id, parent: parent, title: title, isFolder: type == 2, date: date, url: url)
            childrenOf[parent, default: []].append(id)
        }
        func build(_ id: Int) -> BookmarkNode? {
            guard let node = nodes[id] else { return nil }
            if node.isFolder {
                let kids = (childrenOf[id] ?? []).compactMap { build($0) }
                return BookmarkNode(kind: .folder, title: node.title, dateAdded: node.date, children: kids)
            }
            guard let url = node.url, !url.isEmpty else { return nil }
            return BookmarkNode(kind: .link, title: node.title.isEmpty ? url : node.title, url: url, dateAdded: node.date)
        }
        // Root ids in Firefox: 1 = root, 2 = menu, 3 = toolbar, 4 = unfiled, 5 = mobile, 6 = tags.
        let names: [Int: (String, String)] = [
            3: ("bookmark_bar", "Bookmarks Toolbar"),
            2: ("menu", "Bookmarks Menu"),
            4: ("other", "Other Bookmarks"),
            5: ("mobile", "Mobile Bookmarks"),
        ]
        var roots: [BookmarkTree.RootFolder] = []
        for id in [3, 2, 4, 5] {
            guard let (key, title) = names[id], let node = build(id) else { continue }
            if node.children.isEmpty && node.kind == .folder { continue }
            roots.append(.init(id: key, title: node.title.isEmpty ? title : node.title, node: node))
        }
        if roots.isEmpty, let root = build(1) { roots = [.init(id: "other", title: "Bookmarks", node: root)] }
        return BookmarkTree(source: "firefox", roots: roots)
    }
}

/// Generic, user-facing error for the file-format helpers.
///
/// Kept separate from `ChromiumBookmarks.ParseError` so the CLI never prefixes an unrelated
/// failure with "invalid Chromium bookmark JSON".
public enum BookmarkError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case unknownBrowser(String, known: [String])
    case noBookmarkFiles(String)
    case unreadable(String, String)
    case notABookmarkFile(String)
    case noBookmarksFound(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let f):
            return "unknown format '\(f)' (use html, chromium or json)"
        case .unknownBrowser(let name, let known):
            return "unknown browser '\(name)'. Known: \(known.joined(separator: ", ")), all"
        case .noBookmarkFiles(let name):
            return "no bookmark files found for '\(name)' on this Mac"
        case .unreadable(let path, let why):
            return "cannot read \(path): \(why)"
        case .notABookmarkFile(let path):
            return "\(path) does not look like a bookmark file (pass --format html|chromium|json)"
        case .noBookmarksFound(let what):
            return "no bookmarks found in \(what)"
        }
    }
}
