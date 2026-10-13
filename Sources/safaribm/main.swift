import Foundation
import SafariBookmarksCore

@main
struct Safaribm {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            print(Self.usage)
            exit(args.isEmpty ? 2 : 0)
        }
        let command = args.removeFirst()
        do {
            switch command {
            case "read": try Commands.read(args)
            case "profiles": try Commands.profiles(args)
            case "import": try Commands.importBookmarks(args)
            case "export": try Commands.export(args)
            case "browsers": try Commands.browsers(args)
            case "inspect": try Commands.inspect(args)
            case "debug": try Commands.debug(args)
            case "convert": try Commands.convert(args)
            case "-h", "--help", "help": print(Self.usage)
            case "--version", "version": print("safaribm \(Self.version)")
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
    safaribm \(version) — read, export and import Safari bookmarks

    USAGE
      safaribm <command> [options]

    COMMANDS
      read        Print Safari's bookmark tree (text or JSON)
      profiles    List Safari profiles and their bookmark counts
      export      Export Safari bookmarks to another browser's format
      import      Import another browser's bookmarks into Safari
      convert     Convert between bookmark file formats without touching Safari
      browsers    List browsers and profiles detected on this Mac
      inspect     Dump reverse-engineering details (paths, private API methods)

    Run `safaribm <command> --help` for command-specific options.
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
        safaribm read — print Safari's bookmark tree

        OPTIONS
          --format text|json     output format (default: text)
          --db <path>            read a copy of SafariTabs.db instead of the live database
          --profile <name|id>    restrict output to one profile
          --hidden               include hidden folders and special roots
          --class <name>         (advanced) dump a private class instead of bookmarks

        The live database lives at
          ~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db
        """)
            return
        }
        let path = a.value("db") ?? SafariBridge.safariDatabasePath()
        let handle = try SafariBridge.open(path: path)
        let model = try SafariModel(handle: handle)

        if a.has("class") || a.value("class") != nil {
            let cls = a.value("class") ?? "WebBookmarkCollection"
            for line in SafariBridge.dumpMethods(of: cls) { print(line) }
            return
        }

        let tree = try model.tree(
            profile: a.value("profile"),
            includeHidden: a.has("hidden"),
            includeReadingList: a.has("reading-list") || a.has("readinglist")
        )
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
            safaribm profiles — list Safari profiles

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
                print(String(format: "  #%-4d %-24s  %4d links  %3d folders", p.id, (p.title as NSString).utf8String!, p.linkCount, p.folderCount))
            }
        }
    }

    // MARK: - export

    static func export(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") {
            print("""
            safaribm export — export Safari bookmarks for another browser

            OPTIONS
              --format html|chromium|json   output format (default: html)
                                            html      Netscape bookmarks.html
                                            chromium  Chrome/Edge/Brave "Bookmarks" JSON
                                            json      this tool's own JSON tree
              --out, -o <path>              write to a file (default: stdout)
              --profile <name|id>           export a single profile
              --title <name>                folder title to wrap the export in
              --only <substr>               keep only folders whose title matches
              --exclude <substr>            drop folders whose title matches
              --no-reading-list             skip the reading list
              --hidden                      include hidden folders

            EXAMPLES
              safaribm export --format html --out ~/Desktop/safari-bookmarks.html
              safaribm export --format chromium --out ~/chromium-Bookmarks
            """)
            return
        }
        let format = (a.value("format", "f") ?? "html").lowercased()
        let handle = try SafariBridge.open(path: a.value("db") ?? SafariBridge.safariDatabasePath())
        let model = try SafariModel(handle: handle)
        var tree = try model.tree(
            profile: a.value("profile"),
            includeHidden: a.has("hidden"),
            includeReadingList: !a.has("no-reading-list")
        )
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
            safaribm import — import bookmarks from another browser into Safari

            OPTIONS
              --source, -s <path>        file to import (required)
              --format, -f <format>      auto (default) | html | chromium | json | auto-browser
              --browser, -b <name>       read a browser's own bookmark file:
                                         chrome | edge | brave | chromium | opera | vivaldi | all
              --profile <name|id>        Safari profile to import into (default: first profile)
              --parent <id>              explicit destination folder id (advanced)
              --title <name>             container folder name (default: "Imported <date>")
              --no-container             import directly into the destination folder
              --dedupe                   skip bookmarks whose URL is already in the destination
              --dry-run                  show what would happen, change nothing
              --yes                      skip the confirmation prompt
              --undo <folderID>          delete a folder created by an earlier import
                                         (the id is printed at the end of every import)

            EXAMPLES
              safaribm import --browser edge --dry-run
              safaribm import --source ~/Downloads/bookmarks.html --yes
              safaribm import --browser chrome --profile Work --title "From Chrome"
              safaribm import --undo 52
            """)
            return
        }

        if let undoID = a.int("undo") {
            try undoImport(folderID: undoID, database: a.value("db"), assumeYes: a.has("yes"))
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
            let parsed = try BookmarkFile.read(path: source, explicitFormat: a.value("format", "f"))
            tree = parsed
            sourceDescription = source
        } else {
            throw Fail.message("provide --source <file> or --browser <name> (see --help)")
        }

        guard var imported = tree else { throw Fail.message("nothing to import") }
        imported = Filtering.apply(
            imported,
            only: a.value("only"),
            exclude: a.value("exclude"),
            wrapTitle: nil,
            flatten: a.has("flatten")
        )
        guard imported.linkCount > 0 else { throw Fail.message("the source contains no bookmarks") }

        let handle = try SafariBridge.open(path: a.value("db") ?? SafariBridge.safariDatabasePath())
        let model = try SafariModel(handle: handle)

        // Pick the destination folder.
        let destination: SafariModel.Destination
        if let parent = a.int("parent") {
            destination = SafariModel.Destination(parentID: parent, description: "folder #\(parent)")
        } else if let element = try model.destination(profileNamed: a.value("profile")) {
            destination = element
        } else {
            throw Fail.message("""
            could not find a writable destination folder in Safari.
            Make sure Safari has run at least once on this account, or pass --parent <folder id>.
            """)
        }

        let containerTitle = a.value("title") ?? defaultContainerTitle()
        var nodes = imported.roots.map(\.node)

        // --dedupe: drop links whose URL is already somewhere under the destination.
        if a.has("dedupe") {
            let existing = model.existingURLs(under: destination.parentID)
            let before = imported.linkCount
            let deduped = BookmarkTree(
                source: imported.source,
                roots: imported.roots.compactMap { root in
                    Dedupe.prune(root.node, existing: existing).map {
                        BookmarkTree.RootFolder(id: root.id, title: root.title, node: $0)
                    }
                }
            )
            let removed = before - deduped.linkCount
            nodes = deduped.roots.map(\.node)
            imported = deduped
            print("dedupe       \(removed) already present, \(deduped.linkCount) remain")
            guard deduped.linkCount > 0 else { throw Fail.message("every bookmark is already in the destination (nothing to do)") }
        }

        print("source       \(sourceDescription)")
        print("found        \(imported.linkCount) bookmarks in \(imported.folderCount) folders")
        print("destination  \(destination.description)  [\(handle.databasePath)]")
        if a.has("no-container") {
            print("container    (none — importing directly into the destination)")
        } else {
            print("container    \(containerTitle)")
        }
        if dryRun {
            print("\n--dry-run: nothing was written. Tree that would be imported:")
            print(TextOutput.render(imported, maxDepth: a.int("max-depth"), limit: a.int("max-entries")))
            return
        }
        guard SafariBridge.isWritable(handle) else {
            throw Fail.message("""
            \(handle.databasePath) is not writable.

            Safari stores bookmarks inside its sandbox container. Run this command with an
            unsandboxed process (a normal terminal is fine) or grant Full Disk Access to the
            terminal in System Settings › Privacy & Security › Full Disk Access.
            """)
        }

        if !a.has("yes") && !confirm("Import into \(destination.description)?") {
            throw Fail.message("aborted")
        }

        let request = SafariBridge.ImportRequest(
            parentID: destination.parentID,
            containerTitle: a.has("no-container") ? "" : containerTitle,
            nodes: nodes,
            reuseExistingContainer: !a.has("no-container")
        )
        let result: SafariBridge.ImportResult
        if a.has("no-container") {
            result = try importDirect(handle: handle, parentID: destination.parentID, nodes: nodes)
        } else {
            result = try SafariBridge.importNodes(handle, request: request)
        }
        SafariBridge.notifySafariToReload()
        print("\nimported     \(result.linkCount) bookmarks, \(result.folderCount) folders")
        print("container    #\(result.containerID) \(result.destination)\(result.createdContainer ? " (created)" : " (reused)")")
        print("\nSafari has been asked to reload its bookmarks. If the sidebar does not update,")
        print("quit and reopen Safari (⌘Q) — the change is already committed to the database.")
        print("\nTo undo this import: safaribm import --undo \(result.containerID)")
    }

    /// Removes a folder created by a previous import, together with everything inside it.
    static func undoImport(folderID: Int, database: String?, assumeYes: Bool) throws {
        let path = database ?? SafariBridge.safariDatabasePath()
        let model = try SafariModel(databasePath: path)
        guard let folder = model.row(folderID), folder.isFolder else {
            throw Fail.message("no folder #\(folderID) in \(path)")
        }
        let links = model.subtreeLinkCount(folderID)
        let folders = model.subtreeFolderCount(folderID)
        print("folder       #\(folderID) '\(folder.title)' in \(path)")
        print("contains     \(links) bookmarks in \(folders) folders")
        if !assumeYes && !confirm("Delete this folder and everything inside it from Safari?") {
            throw Fail.message("aborted")
        }
        let handle = try SafariBridge.open(path: path)
        try SafariBridge.deleteFolder(handle, id: folderID)
        SafariBridge.notifySafariToReload()
        print("deleted      #\(folderID) '\(folder.title)'")
    }

    /// Imports straight into an existing folder, without creating a container.
    static func importDirect(handle: SafariBridge.Handle, parentID: Int, nodes: [BookmarkNode]) throws -> SafariBridge.ImportResult {
        try SafariBridge.importNodes(
            handle,
            request: .init(parentID: parentID, containerTitle: "", nodes: nodes, reuseExistingContainer: true)
        )
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
            safaribm convert — convert between bookmark file formats (never touches Safari)

            OPTIONS
              --source, -s <path>      input file (required)
              --format, -f <format>    input format: auto (default) | html | chromium | json
              --type, -t <format>      output format: html | chromium | json (default: html)
              --out, -o <path>         output file (default: stdout)
              --flatten                drop folder nesting, keep one flat list

            EXAMPLES
              safaribm convert -s ~/edge-Bookmarks -t html -o ~/edge.html
              safaribm convert -s ~/safari.html -t chromium -o ~/chromium-Bookmarks
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
            safaribm browsers — list browsers with bookmark files on this Mac

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
                "safari": ["database": SafariBridge.safariDatabasePath()],
                "browsers": installed.map { browser in
                    ["name": browser.name, "profiles": browser.profiles.map { ["path": $0.path, "label": $0.label] }]
                },
            ]
            print(try JSONOutput.string(payload))
            return
        }
        print("safari")
        print("  database  \(SafariBridge.safariDatabasePath())")
        let present = FileManager.default.fileExists(atPath: SafariBridge.safariDatabasePath())
        print("  present   \(present)")
        if present, let model = try? SafariModel(databasePath: SafariBridge.safariDatabasePath()) {
            for p in model.profiles {
                print("  profile   #\(p.localFolderID) '\(p.title)'  \(p.linkCount) bookmarks")
            }
        }
        if installed.isEmpty { print("\nno other browsers with bookmark files were found") }
        for browser in installed {
            print("\n\(browser.name)")
            for profile in browser.profiles {
                print("  \(profile.label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(profile.path)")
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
            safaribm inspect — reverse-engineering details

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
