import Foundation
import MarkSyncCore

extension Commands {

    // MARK: - sync

    static let syncHelp = """
    marksync sync — copy bookmarks from one browser into another, keeping their place

    USAGE
      marksync sync --from <browser> --to <browser> [options]

      <browser>  safari | chrome | edge | brave | chromium | vivaldi | opera
                 arc and firefox can only be a source (--from)

    WHAT GOES WHERE
      bookmarks bar / 收藏夹栏    <->  Safari Favorites (个人收藏)
      other bookmarks / 其他收藏夹 <->  the top level of Safari's bookmarks sidebar
      mobile bookmarks           ->   a "Mobile bookmarks" folder in Safari's sidebar

      Nothing is ever deleted or moved in the target. Folders are matched by name, and a
      bookmark whose URL the target already has is skipped, so running the same sync
      again adds nothing.

    OPTIONS
      --from <browser>           where bookmarks come from (required)
      --to <browser>             where they go (required)
      --from-profile <name>      Chromium source profile: "Default", "Profile 1" or its
                                 display name (default: Default, or the only profile that
                                 has bookmarks)
      --to-profile <name>        Chromium target profile, same rules
      --bar-only                 only sync the bookmarks bar / Favorites
      --dry-run                  show exactly what would be added, change nothing
      --yes                      skip the confirmation prompt
      --undo <log|last>          revert a previous sync (every sync prints its log path)

    The target browser must be quit (⌘Q): browsers keep bookmarks in memory and overwrite
    the file when they exit. Safari bookmarks are not per-profile, so Safari takes no profile.

    SAFARI AND iCLOUD
      Safari's bookmarks are ~/Library/Safari/Bookmarks.plist. New items are appended without
      touching existing ones or their iCloud metadata; Safari uploads them on its next sync.
      A backup is kept next to the file, and --undo removes exactly the items a sync added.

    EXAMPLES
      marksync sync --from edge --to safari --dry-run
      marksync sync --from edge --to safari --yes
      marksync sync --from safari --to chrome --to-profile "Profile 1"
      marksync sync --from chrome --to edge --bar-only
      marksync sync --undo last
    """

    static func sync(_ argv: [String]) throws {
        let a = try Args(argv)
        if a.has("help") { print(syncHelp); return }
        if let undo = a.value("undo") ?? (a.has("undo") ? "last" : nil) {
            try undoSync(undo, assumeYes: a.has("yes"))
            return
        }
        guard let from = a.value("from")?.lowercased(), let to = a.value("to")?.lowercased() else {
            throw Fail.message("choose a direction with --from <browser> --to <browser> (see `marksync sync --help`)")
        }
        guard from != to || a.value("from-profile") != a.value("to-profile") else {
            throw Fail.message("--from and --to are the same browser and profile")
        }

        // Source
        var (source, sourceDescription) = try readSyncSource(from, profile: a.value("from-profile"))
        if a.has("bar-only") {
            source.nodes = source.nodes.filter { $0.key == .bar }
        }
        guard source.linkCount > 0 else {
            throw Fail.message("\(sourceDescription) has no bookmarks to sync" + otherProfilesHint(from, excluding: sourceDescription))
        }

        // Target and plan
        let target = try openSyncTarget(to, profile: a.value("to-profile"))
        let plan = BookmarkMerge.plan(source: source, target: target.slots)

        print("from     \(sourceDescription)  (\(source.linkCount) bookmarks)")
        print("to       \(target.description)")
        for slot in plan.folded {
            print("note     \(target.name) has no \(slot.rawValue) folder; those bookmarks go into a folder in 'other'")
        }
        if let note = target.note { print("note     \(note)") }
        print("")
        if plan.isEmpty {
            print("already in sync: all \(plan.skipped) bookmarks are present in \(target.name). Nothing to do.")
            return
        }
        for insertion in plan.insertions {
            let links = insertion.nodes.reduce(0) { $0 + $1.linkCount }
            let folders = insertion.nodes.reduce(0) { $0 + $1.folderCount }
            print("  + \(links) bookmarks\(folders > 0 ? ", \(folders) folders" : "")  →  \(insertion.path)")
        }
        print("\nadd      \(plan.linkCount) bookmarks, \(plan.folderCount) folders")
        print("skip     \(plan.skipped) already present")

        if a.has("dry-run") || a.has("n") {
            let roots = plan.insertions.enumerated().map { index, insertion in
                BookmarkTree.RootFolder(id: "insert-\(index)", title: "→ \(insertion.path)", node: .folder("→ \(insertion.path)", children: insertion.nodes))
            }
            print("\n--dry-run: nothing was written. What would be added:")
            print(TextOutput.render(BookmarkTree(source: "plan", roots: roots), maxDepth: a.int("max-depth"), limit: a.int("max-entries")))
            return
        }
        if target.runningCheck() {
            throw SyncError.browserRunning(target.name)
        }
        if !a.has("yes") && !confirm("Add these to \(target.name)?") {
            throw Fail.message("aborted")
        }

        let log = try target.apply(plan, from)
        let logPath = try log.save()
        print("\ndone     added \(plan.linkCount) bookmarks to \(target.name)")
        print("undo     marksync sync --undo \"\(logPath)\"   (or: marksync sync --undo last)")
        if to == "safari" {
            print("\nOpen Safari to see them. With iCloud on, Safari uploads them on its next sync.")
        }
    }

    /// Reads one browser's bookmarks, sorted into slots.
    static func readSyncSource(_ browser: String, profile: String?) throws -> (SlottedBookmarks, String) {
        switch browser {
        case "safari":
            if profile != nil { print("note     Safari bookmarks are shared by all profiles; --from-profile is ignored") }
            let plist = try SafariBookmarksPlist.load(path: SafariBookmarksPlist.defaultPath())
            return (plist.syncSource(), "Safari")
        case "firefox":
            var files = BrowserLocator.firefoxBookmarkFiles()
            if let profile { files = files.filter { $0.label.lowercased().contains(profile.lowercased()) } }
            guard let file = files.first else { throw BookmarkError.noBookmarkFiles("firefox") }
            let tree = try BookmarkFile.read(path: file.path, explicitFormat: "firefox")
            return (SlottedBookmarks(tree), file.label)
        default:
            var chromium = try BrowserLocator.chromiumProfile(browser: browser, named: profile)
            // No profile asked for and `Default` is empty: a signed-in user's bookmarks often live
            // in `Profile N` instead. Use that profile when it is the only one with bookmarks.
            if profile == nil, (chromium.sourceFile.flatMap { BrowserLocator.chromiumLinkCount(path: $0.path) } ?? 0) == 0,
               let candidate = BrowserLocator.candidate(named: browser) {
                let nonEmpty = BrowserLocator.chromiumProfiles(candidate).filter { p in
                    (p.sourceFile.flatMap { BrowserLocator.chromiumLinkCount(path: $0.path) } ?? 0) > 0
                }
                if nonEmpty.count == 1 {
                    chromium = nonEmpty[0]
                    print("note     \(candidate.name) Default has no bookmarks; using \(chromium.label) (pick another with --from-profile)")
                }
            }
            guard let file = chromium.sourceFile else { throw BookmarkError.noBookmarksFound(chromium.label) }
            let tree = try BookmarkFile.read(path: file.path, explicitFormat: "chromium")
            return (SlottedBookmarks(tree), file.label)
        }
    }

    /// When the chosen Chromium profile is empty, lists the browser's other profiles with their
    /// bookmark counts: the usual cause is that the bookmarks live in `Profile 1`, not `Default`.
    static func otherProfilesHint(_ browser: String, excluding label: String) -> String {
        guard let candidate = BrowserLocator.candidate(named: browser) else { return "" }
        let lines = BrowserLocator.chromiumProfiles(candidate).compactMap { profile -> String? in
            guard let file = profile.sourceFile, file.label != label else { return nil }
            let count = BrowserLocator.chromiumLinkCount(path: file.path) ?? 0
            return "  \(count) bookmarks  \(file.label)  →  --from-profile \"\(profile.directoryName)\""
        }
        guard !lines.isEmpty else { return "" }
        return "\n\nother \(candidate.name) profiles:\n" + lines.joined(separator: "\n")
    }

    /// One end of a sync that can be written to.
    struct SyncTarget {
        var name: String
        var description: String
        var note: String?
        var slots: [BookmarkSlot: BookmarkMerge.TargetFolder]
        /// True when the target app is running and must be quit before writing.
        var runningCheck: () -> Bool
        var apply: (BookmarkMerge.Plan, String) throws -> SyncUndoLog
    }

    static func openSyncTarget(_ browser: String, profile: String?) throws -> SyncTarget {
        switch browser {
        case "safari":
            if profile != nil { print("note     Safari bookmarks are shared by all profiles; --to-profile is ignored") }
            let path = SafariBookmarksPlist.defaultPath()
            let snapshot = FileSnapshot(path: path)
            let plist = try SafariBookmarksPlist.load(path: path)
            return SyncTarget(
                name: "Safari",
                description: "Safari  (bar → Favorites, other → bookmarks sidebar)  [\(path)]",
                slots: plist.mergeTarget(),
                runningCheck: { BrowserLocator.isRunning(bundleIdentifier: BrowserLocator.safariBundleIdentifier) },
                apply: { plan, from in try applyToSafari(plan, plist: plist, snapshot: snapshot, from: from) }
            )
        case "firefox":
            throw SyncError.notWritable("Firefox", "marksync can read Firefox but not write it. Use `marksync export --format html` and Firefox's own import.")
        default:
            let chromium = try BrowserLocator.chromiumProfile(browser: browser, named: profile)
            guard chromium.browser.isWritable else {
                throw SyncError.notWritable(chromium.browser.name, "its sidebar is not stored in a Chromium Bookmarks file")
            }
            let snapshot = FileSnapshot(path: chromium.bookmarksPath)
            let document = try ChromiumDocument.load(path: chromium.bookmarksPath)
            var note: String?
            if let count = BrowserLocator.chromiumLinkCount(path: chromium.accountBookmarksPath), count > 0 {
                note = "this profile also has \(count) account bookmarks; new bookmarks go to the local (\"on this device\") set"
            }
            return SyncTarget(
                name: chromium.label,
                description: "\(chromium.label)  [\(chromium.bookmarksPath)]",
                note: note,
                slots: document.mergeTarget(),
                runningCheck: { BrowserLocator.isRunning(chromium.browser) },
                apply: { plan, from in try applyToChromium(plan, document: document, snapshot: snapshot, profile: chromium, from: from) }
            )
        }
    }

    /// Copies `path` aside before it is rewritten and returns the copy's path.
    static func backup(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // A sync and its undo can land in the same second; never reuse a backup name.
        let stem = "\(path).marksync-\(SyncUndoLog.timestamp())"
        var copy = "\(stem).bak"
        var n = 1
        while FileManager.default.fileExists(atPath: copy) {
            n += 1
            copy = "\(stem)-\(n).bak"
        }
        try FileManager.default.copyItem(atPath: path, toPath: copy)
        return copy
    }

    /// Refuses to overwrite a file that something else wrote since it was read — for Safari,
    /// typically the iCloud bookmarks agent.
    static func ensureUnchanged(_ snapshot: FileSnapshot) throws {
        guard snapshot.isUnchanged else {
            throw Fail.message("\(snapshot.path) changed while marksync was running (iCloud sync or the browser). Nothing was written; run the command again.")
        }
    }

    static func applyToSafari(_ plan: BookmarkMerge.Plan, plist: SafariBookmarksPlist, snapshot: FileSnapshot, from: String) throws -> SyncUndoLog {
        guard !BrowserLocator.isRunning(bundleIdentifier: BrowserLocator.safariBundleIdentifier) else {
            throw SyncError.browserRunning("Safari")
        }
        var created: [String] = []
        for insertion in plan.insertions {
            created += try plist.insert(insertion.nodes, into: insertion.parentRef)
        }
        let data = try plist.data()
        try ensureUnchanged(snapshot)
        let backupPath = try backup(snapshot.path)
        try data.write(to: URL(fileURLWithPath: snapshot.path), options: .atomic)
        return SyncUndoLog(from: from, to: "safari", safariPlist: snapshot.path, createdUUIDs: created, backupFile: backupPath)
    }

    static func applyToChromium(_ plan: BookmarkMerge.Plan, document: ChromiumDocument, snapshot: FileSnapshot, profile: ChromiumProfile, from: String) throws -> SyncUndoLog {
        guard !BrowserLocator.isRunning(profile.browser) else { throw SyncError.browserRunning(profile.browser.name) }
        for insertion in plan.insertions {
            try document.insert(insertion.nodes, into: insertion.parentRef)
        }
        let data = try document.data()
        try ensureUnchanged(snapshot)
        let backupPath = try backup(snapshot.path)
        try data.write(to: URL(fileURLWithPath: snapshot.path), options: .atomic)
        return SyncUndoLog(from: from, to: profile.browser.name, bookmarksFile: snapshot.path, backupFile: backupPath)
    }

    static func undoSync(_ which: String, assumeYes: Bool) throws {
        let (path, log) = try SyncUndoLog.load(which)
        print("undo     \(log.from) → \(log.to), synced \(log.date)")
        print("log      \(path)")
        if let uuids = log.createdUUIDs, let plistPath = log.safariPlist {
            guard !BrowserLocator.isRunning(bundleIdentifier: BrowserLocator.safariBundleIdentifier) else {
                throw SyncError.browserRunning("Safari")
            }
            let snapshot = FileSnapshot(path: plistPath)
            let plist = try SafariBookmarksPlist.load(path: plistPath)
            let set = Set(uuids)
            let links = plist.linkCount(uuids: set)
            print("removes  the \(uuids.count) items (\(links) bookmarks) the sync added to Safari; everything else stays")
            if !assumeYes && !confirm("Remove them from Safari?") { throw Fail.message("aborted") }
            let removed = plist.remove(uuids: set)
            guard removed > 0 else { print("nothing left to remove"); try FileManager.default.removeItem(atPath: path); return }
            let data = try plist.data()
            try ensureUnchanged(snapshot)
            _ = try backup(plistPath)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } else if let ids = log.createdIDs, let database = log.safariDatabase {
            // Logs from the earlier SafariTabs.db writer.
            let model = try SafariModel(databasePath: database)
            let present = ids.filter { model.row($0) != nil }
            print("removes  \(present.count) items the sync wrote to SafariTabs.db (they were never shown by Safari)")
            guard !present.isEmpty else { print("nothing left to remove"); try FileManager.default.removeItem(atPath: path); return }
            if !assumeYes && !confirm("Remove them?") { throw Fail.message("aborted") }
            let handle = try SafariBridge.open(path: database)
            for id in present.reversed() { try SafariBridge.deleteFolder(handle, id: id) }
        } else if let file = log.bookmarksFile {
            if let candidate = BrowserLocator.candidate(named: log.to), BrowserLocator.isRunning(candidate) {
                throw SyncError.browserRunning(candidate.name)
            }
            let action = log.backupFile.map { "restores \(file) from \($0)" } ?? "removes \(file), which the sync created"
            print("action   \(action)")
            print("         (bookmark changes made in \(log.to) after the sync are lost)")
            if !assumeYes && !confirm("Continue?") { throw Fail.message("aborted") }
            if let backup = log.backupFile {
                let data = try Data(contentsOf: URL(fileURLWithPath: backup))
                try data.write(to: URL(fileURLWithPath: file), options: .atomic)
            } else {
                try FileManager.default.removeItem(atPath: file)
            }
        } else {
            throw SyncError.noUndoLog("contents at \(path)")
        }
        try FileManager.default.removeItem(atPath: path)
        print("reverted")
    }
}
