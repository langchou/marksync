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
        public var applicationSupportPath: String
        public var bookmarkFileName: String
        public var profileSubdirectories: [String]
    }

    /// Chromium-family browsers keep `…/Application Support/<vendor>/<profile>/Bookmarks`.
    public static let chromiumBrowsers: [Candidate] = [
        .init(name: "chrome", applicationSupportPath: "Google/Chrome", bookmarkFileName: "Bookmarks", profileSubdirectories: ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4", "Profile 5"]),
        .init(name: "edge", applicationSupportPath: "Microsoft Edge", bookmarkFileName: "Bookmarks", profileSubdirectories: ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4", "Profile 5"]),
        .init(name: "brave", applicationSupportPath: "BraveSoftware/Brave-Browser", bookmarkFileName: "Bookmarks", profileSubdirectories: ["Default", "Profile 1", "Profile 2", "Profile 3"]),
        .init(name: "chromium", applicationSupportPath: "Chromium", bookmarkFileName: "Bookmarks", profileSubdirectories: ["Default", "Profile 1", "Profile 2"]),
        .init(name: "vivaldi", applicationSupportPath: "Vivaldi", bookmarkFileName: "Bookmarks", profileSubdirectories: ["Default", "Profile 1"]),
        .init(name: "opera", applicationSupportPath: "com.operasoftware.Opera", bookmarkFileName: "Bookmarks", profileSubdirectories: [""]),
        .init(name: "arc", applicationSupportPath: "Arc", bookmarkFileName: "Bookmarks", profileSubdirectories: ["User Data/Default"]),
    ]

    public static func home(_ override: String? = nil) -> String {
        override ?? SafariBridge.realHomeDirectory()
    }

    /// The bookmark files for one browser name, or every known browser for `all`.
    public static func bookmarkFiles(forBrowser name: String, home homeOverride: String? = nil) throws -> [BookmarkFile.Info] {
        let wanted = name.lowercased()
        let base = home(homeOverride) + "/Library/Application Support"
        var candidates = chromiumBrowsers
        if wanted == "all" || wanted == "auto" {
            // keep the full list
        } else {
            candidates = chromiumBrowsers.filter { $0.name == wanted }
            let known = chromiumBrowsers.map(\.name) + ["firefox"]
            if candidates.isEmpty && !known.contains(wanted) {
                throw BookmarkError.unknownBrowser(name, known: known)
            }
        }

        var out: [BookmarkFile.Info] = []
        for candidate in candidates {
            for profile in candidate.profileSubdirectories {
                var dir = "\(base)/\(candidate.applicationSupportPath)"
                if !profile.isEmpty { dir += "/\(profile)" }
                let file = "\(dir)/\(candidate.bookmarkFileName)"
                guard FileManager.default.fileExists(atPath: file) else { continue }
                let label = profile.isEmpty ? candidate.name : "\(candidate.name) \(profile)"
                out.append(.init(path: file, format: .chromiumJSON, label: label))
            }
        }

        // Firefox stores bookmarks inside `places.sqlite`; exporting requires reading it.
        if wanted == "firefox" || wanted == "all" || wanted == "auto" {
            out.append(contentsOf: firefoxBookmarkFiles(home: homeOverride))
        }

        return out
    }

    /// Firefox keeps bookmarks in SQLite. We surface the database and let the caller decide,
    /// since converting it needs `moz_bookmarks`/`moz_places` joins.
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
