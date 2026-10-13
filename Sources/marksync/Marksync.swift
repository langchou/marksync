import Foundation
import MarkSyncCore

@main
struct Marksync {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            print(Self.usage)
            exit(args.isEmpty ? 2 : 0)
        }
        let command = args.removeFirst()
        do {
            switch command {
            case "sync": try Commands.sync(args)
            case "read": try Commands.read(args)
            case "profiles": try Commands.profiles(args)
            case "import": try Commands.importBookmarks(args)
            case "export": try Commands.export(args)
            case "browsers": try Commands.browsers(args)
            case "inspect": try Commands.inspect(args)
            case "debug": try Commands.debug(args)
            case "convert": try Commands.convert(args)
            case "-h", "--help", "help": print(Self.usage)
            case "--version", "version": print("marksync \(Self.version)")
            default:
                FileHandle.standardError.write("unknown command: \(command)\n\n".data(using: .utf8)!)
                print(Self.usage)
                exit(2)
            }
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static let version = "0.1.0"

    static let usage = """
    marksync \(version) — sync bookmarks between Safari, Chrome, Edge and other browsers

    USAGE
      marksync <command> [options]

    COMMANDS
      sync        Sync bookmarks from one browser to another (you pick the direction)
      read        Print Safari's bookmark tree (text or JSON)
      profiles    List Safari profiles and their bookmark counts
      export      Export Safari bookmarks to another browser's format
      import      Import another browser's bookmarks into Safari
      convert     Convert between bookmark file formats without touching Safari
      browsers    List browsers and profiles detected on this Mac
      inspect     Dump reverse-engineering details (paths, private API methods)

    Run `marksync <command> --help` for command-specific options.
    """
}

enum Fail: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "" }
}

/// Minimal GNU-style option parser: `--flag`, `--key value`, `--key=value`, `-k value`.
struct Args {
    private var flags: Set<String> = []
    private var values: [String: String] = [:]
    private var positional: [String] = []

    init(_ argv: [String]) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    values[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                } else if let next = argv[safe: i + 1], !next.hasPrefix("-"), Self.takesValue(body) {
                    values[body] = next
                    i += 1
                } else {
                    flags.insert(body)
                }
            } else if a.hasPrefix("-") && a.count > 1 {
                let body = String(a.dropFirst())
                if let next = argv[safe: i + 1], !next.hasPrefix("-"), Self.takesValue(body) {
                    values[body] = next
                    i += 1
                } else {
                    flags.insert(body)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    /// Option names that consume a following argument rather than acting as booleans.
    private static let valueOptions: Set<String> = [
        "out", "output", "o", "format", "f", "profile", "p", "parent", "source", "s",
        "type", "t", "name", "db", "browser", "b", "indent", "title", "into", "only",
        "exclude", "flatten", "max-depth", "dedupe", "class", "max-entries", "max-depth", "undo",
        "from", "to", "from-profile", "to-profile",
    ]
    private static func takesValue(_ name: String) -> Bool { valueOptions.contains(name) }

    func has(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }
    func value(_ names: [String]) -> String? {
        for n in names { if let v = values[n] { return v } }
        return nil
    }

    func value(_ names: String...) -> String? { value(names) }
    var rest: [String] { positional }
    func require(_ name: String, _ names: String...) throws -> String {
        if let v = value([name] + names) { return v }
        throw Fail.message("missing required option --\(name)")
    }
    func int(_ name: String) -> Int? { value(name).flatMap(Int.init) }
    func double(_ name: String) -> Double? { value(name).flatMap(Double.init) }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Shared CLI plumbing.
enum Commands {

    // MARK: - read

    static func read(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") { print("""
        marksync read — print Safari's bookmarks (Favorites, sidebar, reading list)

        OPTIONS
          --format text|json     output format (default: text)
          --no-reading-list      leave out the reading list
          --class <name>         (advanced) dump a private WebBookmarks class instead

        Safari's bookmarks live in ~/Library/Safari/Bookmarks.plist.
        """)
            return
        }
        if a.has("class") || a.value("class") != nil {
            try SafariBridge.loadFramework()
            let cls = a.value("class") ?? "WebBookmarkCollection"
            for line in SafariBridge.dumpMethods(of: cls) { print(line) }
            return
        }
        let tree = try SafariBookmarksPlist.load(path: SafariBookmarksPlist.defaultPath())
            .tree(includeReadingList: !a.has("no-reading-list"))
        if a.value("format", "f") == "json" {
            print(try JSONOutput.string(for: tree))
        } else {
            print(TextOutput.render(tree))
        }
    }

    // MARK: - profiles

    static func profiles(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") {
            print("""
            marksync profiles — list Safari profiles found in SafariTabs.db

            Profiles hold windows and tabs; the counts are tabs, not bookmarks. Safari's
            bookmarks are shared by all profiles and live in Bookmarks.plist (`marksync read`).

            OPTIONS
              --format text|json   output format (default: text)
              --db <path>          read a copy of SafariTabs.db instead of the live database
            """)
            return
        }
        let handle = try SafariBridge.open(path: a.value("db") ?? SafariBridge.safariDatabasePath())
        let model = try SafariModel(handle: handle)
        let profiles = model.profiles
        if a.value("format", "f") == "json" {
            let payload: [String: Any] = [
                "database": handle.databasePath,
                "profiles": profiles.map { ["id": $0.id, "title": $0.title, "bookmarks": $0.linkCount, "folders": $0.folderCount] },
            ]
            print(try JSONOutput.string(payload))
        } else {
            print("database: \(handle.databasePath)")
            if profiles.isEmpty { print("(no profiles found)") }
            for p in profiles {
                print(String(format: "  #%-4d %-24s  %4d tabs", p.id, (p.title as NSString).utf8String!, p.linkCount))
            }
        }
    }

    // MARK: - export

    static func export(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") {
            print("""
            marksync export — export Safari bookmarks for another browser

            OPTIONS
              --format html|chromium|json   output format (default: html)
                                            html      Netscape bookmarks.html
                                            chromium  Chrome/Edge/Brave "Bookmarks" JSON
                                            json      this tool's own JSON tree
              --out, -o <path>              write to a file (default: stdout)
              --title <name>                folder title to wrap the export in
              --only <substr>               keep only folders whose title matches
              --exclude <substr>            drop folders whose title matches
              --no-reading-list             skip the reading list

            EXAMPLES
              marksync export --format html --out ~/Desktop/safari-bookmarks.html
              marksync export --format chromium --out ~/chromium-Bookmarks
            """)
            return
        }
        let format = (a.value("format", "f") ?? "html").lowercased()
        var tree = try SafariBookmarksPlist.load(path: SafariBookmarksPlist.defaultPath())
            .tree(includeReadingList: !a.has("no-reading-list"))
        tree = Filtering.apply(
            tree,
            only: a.value("only"),
            exclude: a.value("exclude"),
            wrapTitle: a.value("title"),
            flatten: a.has("flatten")
        )
        let data = try Serialize.data(tree, format: format)
        try Output.write(data, to: a.value("out", "output", "o"))
        if let out = a.value("out", "output", "o") {
            FileHandle.standardError.write("exported \(tree.linkCount) bookmarks from \(tree.roots.count) root(s) to \(out)\n".data(using: .utf8)!)
        }
    }

    // MARK: - import

    static func importBookmarks(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") {
            print("""
            marksync import — add a file's or another browser's bookmarks to Safari, in one folder

            To merge bookmarks into the matching places instead (bar → Favorites, …), use
            `marksync sync`.

            OPTIONS
              --source, -s <path>        file to import (html, Chromium JSON, tree JSON, places.sqlite)
              --format, -f <format>      auto (default) | html | chromium | json
              --browser, -b <name>       read a browser's own bookmark file:
                                         chrome | edge | brave | chromium | opera | vivaldi | firefox | all
              --title <name>             container folder name (default: "Imported <date>")
              --no-container             add the items directly, without a container folder
              --favorites                add to Favorites instead of the bookmarks sidebar
              --dedupe                   skip bookmarks whose URL Safari already has
              --dry-run                  show what would happen, change nothing
              --yes                      skip the confirmation prompt
              --undo <log|last>          revert an import (same as `marksync sync --undo`)

            Safari must be quit (⌘Q) while marksync writes ~/Library/Safari/Bookmarks.plist.

            EXAMPLES
              marksync import --browser edge --dry-run
              marksync import --source ~/Downloads/bookmarks.html --yes
              marksync import --browser chrome --title "From Chrome" --favorites
              marksync import --undo last
            """)
            return
        }

        if let undo = a.value("undo") ?? (a.has("undo") ? "last" : nil) {
            try undoSync(undo, assumeYes: a.has("yes"))
            return
        }

        let dryRun = a.has("dry-run") || a.has("n")
        var tree: BookmarkTree?
        var sourceDescription = ""

        if let browser = a.value("browser", "b") {
            let files = try BrowserLocator.bookmarkFiles(forBrowser: browser)
            guard !files.isEmpty else { throw BookmarkError.noBookmarkFiles(browser) }
            var roots: [BookmarkTree.RootFolder] = []
            for file in files {
                let parsed = try BookmarkFile.read(path: file.path, explicitFormat: file.format.rawValue)
                // One labelled folder per source file, holding that file's own roots.
                let node = BookmarkNode.folder(file.label, children: parsed.roots.map(\.node))
                guard node.linkCount > 0 else { continue }
                roots.append(.init(id: sanitize(file.label), title: file.label, node: node))
            }
            guard !roots.isEmpty else { throw BookmarkError.noBookmarksFound("'\(browser)'") }
            tree = BookmarkTree(source: "browser", roots: roots)
            sourceDescription = files.map(\.path).joined(separator: ", ")
        } else if let source = a.value("source", "s") {
            tree = try BookmarkFile.read(path: source, explicitFormat: a.value("format", "f"))
            sourceDescription = source
        } else {
            throw Fail.message("provide --source <file> or --browser <name> (see --help)")
        }

        guard var imported = tree else { throw Fail.message("nothing to import") }
        imported = Filtering.apply(imported, only: a.value("only"), exclude: a.value("exclude"), wrapTitle: nil, flatten: a.has("flatten"))
        guard imported.linkCount > 0 else { throw Fail.message("the source contains no bookmarks") }

        let path = SafariBookmarksPlist.defaultPath()
        let snapshot = FileSnapshot(path: path)
        let plist = try SafariBookmarksPlist.load(path: path)
        let targets = plist.mergeTarget()
        let favorites = a.has("favorites")
        guard let parentRef = (favorites ? targets[.bar] : targets[.other])?.ref else {
            throw Fail.message("Safari's Bookmarks.plist has no Favorites folder; open Safari once and try again")
        }

        if a.has("dedupe") {
            var existing: Set<String> = []
            plist.tree().rootNode.walk { node, _ in if let url = node.url { existing.insert(url) } }
            let before = imported.linkCount
            imported = BookmarkTree(source: imported.source, roots: imported.roots.compactMap { root in
                Dedupe.prune(root.node, existing: existing).map { BookmarkTree.RootFolder(id: root.id, title: root.title, node: $0) }
            })
            print("dedupe       \(before - imported.linkCount) already in Safari, \(imported.linkCount) remain")
            guard imported.linkCount > 0 else { throw Fail.message("every bookmark is already in Safari (nothing to do)") }
        }

        let containerTitle = a.value("title") ?? defaultContainerTitle()
        let content = imported.roots.map(\.node)
        let nodes = a.has("no-container") ? content : [.folder(containerTitle, children: content)]

        print("source       \(sourceDescription)")
        print("found        \(imported.linkCount) bookmarks in \(imported.folderCount) folders")
        print("destination  Safari \(favorites ? "Favorites" : "bookmarks sidebar")  [\(path)]")
        print("container    \(a.has("no-container") ? "(none)" : containerTitle)")
        if dryRun {
            print("\n--dry-run: nothing was written. Tree that would be imported:")
            print(TextOutput.render(imported, maxDepth: a.int("max-depth"), limit: a.int("max-entries")))
            return
        }
        guard !BrowserLocator.isRunning(bundleIdentifier: BrowserLocator.safariBundleIdentifier) else {
            throw SyncError.browserRunning("Safari")
        }
        if !a.has("yes") && !confirm("Import into Safari?") { throw Fail.message("aborted") }

        let created = try plist.insert(nodes, into: parentRef)
        let data = try plist.data()
        try ensureUnchanged(snapshot)
        let backupPath = try backup(path)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        let logPath = try SyncUndoLog(from: "import", to: "safari", safariPlist: path, createdUUIDs: created, backupFile: backupPath).save()
        print("\nimported     \(imported.linkCount) bookmarks")
        print("undo         marksync import --undo \"\(logPath)\"   (or: marksync import --undo last)")
    }

    static func defaultContainerTitle() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Imported \(f.string(from: Date()))"
    }

    // MARK: - convert

    static func convert(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") {
            print("""
            marksync convert — convert between bookmark file formats (never touches Safari)

            OPTIONS
              --source, -s <path>      input file (required)
              --format, -f <format>    input format: auto (default) | html | chromium | json
              --type, -t <format>      output format: html | chromium | json (default: html)
              --out, -o <path>         output file (default: stdout)
              --flatten                drop folder nesting, keep one flat list

            EXAMPLES
              marksync convert -s ~/edge-Bookmarks -t html -o ~/edge.html
              marksync convert -s ~/safari.html -t chromium -o ~/chromium-Bookmarks
            """)
            return
        }
        let source = try a.require("source", "s")
        let tree = try BookmarkFile.read(path: source, explicitFormat: a.value("format", "f"))
        let output = Filtering.apply(tree, only: a.value("only"), exclude: a.value("exclude"), wrapTitle: nil, flatten: a.has("flatten"))
        let data = try Serialize.data(output, format: (a.value("type", "t") ?? "html").lowercased())
        try Output.write(data, to: a.value("out", "output", "o"))
    }

    // MARK: - browsers

    static func browsers(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") {
            print("""
            marksync browsers — list browsers with bookmark files on this Mac

            OPTIONS
              --format text|json   output format (default: text)

            Safari itself is always listed first. Chromium-family browsers are read from
            ~/Library/Application Support/<vendor>/<profile>/Bookmarks; Firefox is read from
            places.sqlite in each profile.
            """)
            return
        }
        let installed = BrowserLocator.installed()
        if a.value("format", "f") == "json" {
            let payload: [String: Any] = [
                "safari": ["bookmarks": SafariBookmarksPlist.defaultPath()],
                "browsers": installed.map { browser in
                    ["name": browser.name, "profiles": browser.profiles.map { profile -> [String: Any] in
                        ["path": profile.path, "label": profile.label,
                         "format": profile.format.rawValue,
                         "bookmarks": BrowserLocator.chromiumLinkCount(path: profile.path) ?? 0]
                    }]
                },
            ]
            print(try JSONOutput.string(payload))
            return
        }
        print("safari")
        let plistPath = SafariBookmarksPlist.defaultPath()
        print("  bookmarks \(plistPath)")
        do {
            let slots = try SafariBookmarksPlist.load(path: plistPath).syncSource()
            print("  favorites \(slots.children(.bar).reduce(0) { $0 + $1.linkCount })")
            print("  sidebar   \(slots.children(.other).reduce(0) { $0 + $1.linkCount })")
        } catch {
            print("  (unreadable: \(error))")
        }
        if installed.isEmpty { print("\nno other browsers with bookmark files were found") }
        for browser in installed {
            print("\n\(browser.name)")
            for profile in browser.profiles {
                let count: String
                switch profile.format {
                case .chromiumJSON: count = "\(BrowserLocator.chromiumLinkCount(path: profile.path) ?? 0)"
                case .firefoxSQLite: count = (try? FirefoxBookmarks.parse(path: profile.path).linkCount).map(String.init) ?? "?"
                default: count = "?"
                }
                print("  \(profile.label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(count.padding(toLength: 5, withPad: " ", startingAt: 0)) \(profile.path)")
            }
        }
    }

    // MARK: - debug (hidden)

    static func debug(_ argv: [String]) throws {
        let handle = try SafariBridge.openSafariCollection()
        let model = try SafariModel(databasePath: handle.databasePath)
        print("database      \(model.databasePath)")
        print("special ids   bar=\(model.bookmarksBar.map { String($0.id) } ?? "nil") readingList=\(model.readingListID.map(String.init) ?? "nil") recovered=\(model.recovered.map { String($0.id) } ?? "nil")")
        print("legacy folder \(model.legacyContentFolder.map { "#\($0.id)" } ?? "nil")")
        print("profiles      \(model.profiles.count)")
        for p in model.profiles {
            print("  #\(p.localFolderID) '\(p.title)' private=\(p.privateFolderID.map { "#\($0)" } ?? "-") links=\(p.linkCount) folders=\(p.folderCount)")
        }
        print("activeProfile \(model.activeProfileID().map { "#\($0)" } ?? "nil")")
        print("destination   \((try? model.destination(profileNamed: nil))?.description ?? "nil")")
        print("roots")
        for root in model.allRoots {
            print("  #\(root.id) parent=\(root.parent.map(String.init) ?? "null") special=\(root.specialID) hidden=\(root.hidden) sub=\(root.subtype) kids=\(model.children(root.id).count) '\(root.title)'")
        }
        print("barChildren   \(model.bookmarksBar.map { model.children($0.id).count } ?? -1)")
        for c in model.bookmarksBar.map({ model.children($0.id) }) ?? [] {
            print("  #\(c.id) '\(c.title)' \(c.url ?? "")")
        }
    }

    // MARK: - inspect

    static func inspect(_ argv: [String]) throws {
        let a = try Args(argv)
        let topic = a.rest.first ?? "all"
        if a.has("help") {
            print("""
            marksync inspect — reverse-engineering details

            TOPICS
              paths       where Safari keeps bookmarks on this machine
              api         private classes/methods this tool calls, with type encodings
              schema      the bookmarks table schema of SafariTabs.db
              db          row-level dump of the live bookmark table
              all         everything above (default)
            """)
            return
        }
        let showAll = topic == "all"
        if showAll || topic == "paths" {
            print("== paths")
            print("  real home           \(SafariBridge.realHomeDirectory())")
            print("  home (HOME env)     \(NSHomeDirectory())")
            print("  safari database     \(SafariBridge.safariDatabasePath())")
            let exists = FileManager.default.fileExists(atPath: SafariBridge.safariDatabasePath())
            print("  database present    \(exists)")
            if let legacy = SafariBridge.legacySafariDatabasePath() { print("  legacy database     \(legacy)") }
            print("  framework           \(SafariBridge.frameworkPath)")
            print("  framework loadable  \(SafariBridge.isAvailable)")
            print("  database writable   \(FileManager.default.isWritableFile(atPath: SafariBridge.safariDatabasePath()))")
        }
        if showAll || topic == "api" {
            print("\n== private API")
            let essentials: [(String, String)] = [
                ("WBCollectionConfiguration", "+safariBookmarkCollectionConfiguration"),
                ("WBCollectionConfiguration", "+inMemoryBookmarkCollectionConfiguration"),
                ("WBCollectionConfiguration", "+safariTabCollectionConfiguration"),
                ("WebBookmarkCollection", "+collectionWithConfiguration:"),
                ("WebBookmarkCollection", "-initWithPath:migratingBookmarksPlist:syncAnchorPlist:"),
                ("WebBookmarkCollection", "-bookmarkWithSpecialID:"),
                ("WebBookmarkCollection", "-bookmarkWithID:"),
                ("WebBookmarkCollection", "-listWithID:skipOffset:includeHidden:"),
                ("WebBookmarkCollection", "-rootBookmark"),
                ("WebBookmarkCollection", "-saveBookmark:"),
                ("WebBookmarkCollection", "-deleteBookmark:"),
                ("WebBookmarkCollection", "-moveBookmark:toFolderWithID:orderIndex:"),
                ("WebBookmarkCollection", "-mergeWithBookmarksDictionary:clearHidden:clearSyncData:error:"),
                ("WebBookmarkCollection", "-_databaseTitleForSpecialID:"),
                ("WebBookmark", "-initWithTitle:address:parentID:folder:collectionType:"),
                ("WebBookmark", "-initFolderWithParentID:subtype:collectionType:"),
                ("WebBookmark", "-setTitle:"),
                ("WebBookmark", "-setDateAdded:"),
                ("WebBookmarkList", "-bookmarkAtIndex:skipDecodingSyncData:"),
            ]
            try? SafariBridge.loadFramework()
            for (className, selector) in essentials {
                let probe = safariProbe(className: className, selector: selector)
                print(String(
                    format: "  %-6@ %-28@ %-22@ %@",
                    className as NSString,
                    selector as NSString,
                    (probe.encoding ?? "?") as NSString,
                    probe.exists ? "ok" : "MISSING"
                ))
            }
            print("")
            print("  Type encodings come straight from method_getTypeEncoding: @ is an object,")
            print("  i/q an int/long, B a BOOL, ^@ an NSError** out-parameter.")
        }
        if showAll || topic == "schema" {
            print("\n== SafariTabs.db bookmarks schema")
            if let schema = try? SQLite.schema(path: SafariBridge.safariDatabasePath()).filter({ $0.contains("bookmarks") }) {
                for line in schema { print("  " + line) }
            } else {
                print("  (could not read the schema)")
            }
        }
        if showAll || topic == "db" {
            print("\n== rows")
            let handle = try SafariBridge.open(path: a.value("db") ?? SafariBridge.safariDatabasePath())
            let model = try SafariModel(handle: handle)
            for line in model.rowDump() { print("  " + line) }
        }
        if !showAll && !["paths", "api", "schema", "db"].contains(topic) {
            throw Fail.message("unknown inspect topic '\(topic)' (try: paths, api, schema, db, all)")
        }
    }

    /// Looks up a type encoding and existence for a `+`/`-` selector on a private class.
    /// The leading `+`/`-` must be stripped — `NSSelectorFromString("-foo")` is a different,
    /// never-existing selector called `-foo`.
    static func safariProbe(className: String, selector: String) -> (encoding: String?, exists: Bool) {
        guard let cls = NSClassFromString(className) else { return (nil, false) }
        let isClassMethod = selector.hasPrefix("+")
        let bare = String(selector.dropFirst())   // drop the "+" or "-"
        let target: AnyClass = isClassMethod ? object_getClass(cls)! : cls
        guard let m = class_getInstanceMethod(target, NSSelectorFromString(bare)) else { return (nil, false) }
        return (String(cString: method_getTypeEncoding(m)!), true)
    }
}

func sanitize(_ s: String) -> String {
    let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
    let t = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return t.isEmpty ? "root" : t
}

func confirm(_ prompt: String) -> Bool {
    FileHandle.standardError.write("\(prompt) [y/N] ".data(using: .utf8)!)
    guard let line = readLine() else { return false }
    return line.lowercased().hasPrefix("y")
}

/// `WebBookmark` writes its two flags as arguments after `self`/`_cmd`, so the containerless
/// import path needs the same recursive insert as `importNodes`. Kept here so the request
/// builder stays in one place.
enum SafariDirectImport {
    static func run(handle: SafariBridge.Handle, parentID: Int, nodes: [BookmarkNode]) throws -> SafariBridge.ImportResult {
        try SafariBridge.importNodes(
            handle,
            request: .init(parentID: parentID, containerTitle: "", nodes: nodes, reuseExistingContainer: true)
        )
    }
}
