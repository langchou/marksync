import AppKit
import Foundation

/// Errors from resolving the two ends of a sync.
public enum SyncError: Error, CustomStringConvertible {
    case unknownBrowser(String, known: [String])
    case notWritable(String, String)
    case noProfiles(String)
    case ambiguousProfile(String, [String])
    case noSuchProfile(String, String, [String])
    case browserRunning(String)
    case noUndoLog(String)

    public var description: String {
        switch self {
        case .unknownBrowser(let name, let known):
            return "unknown browser '\(name)'. Known: \(known.joined(separator: ", "))"
        case .notWritable(let name, let why):
            return "cannot sync into \(name): \(why)"
        case .noProfiles(let name):
            return "no \(name) profile found on this Mac — has \(name) been opened at least once?"
        case .ambiguousProfile(let name, let options):
            return "\(name) has several profiles; pick one with --from-profile/--to-profile: \(options.joined(separator: ", "))"
        case .noSuchProfile(let name, let wanted, let options):
            return "no \(name) profile matching '\(wanted)'. Profiles: \(options.joined(separator: ", "))"
        case .browserRunning(let name):
            return "\(name) is running. Quit it first (⌘Q): it keeps bookmarks in memory and would overwrite the file."
        case .noUndoLog(let what):
            return "no sync undo log \(what)"
        }
    }
}

// MARK: - Chromium profiles

/// One profile directory of a Chromium-family browser.
public struct ChromiumProfile {
    public var browser: BrowserLocator.Candidate
    /// The directory name, e.g. `Default` or `Profile 3`; empty for Opera's flat layout.
    public var directoryName: String
    /// The name the user gave the profile, from `Local State`.
    public var displayName: String?
    public var directory: String

    /// The file a sync writes: always the local `Bookmarks` file, never `AccountBookmarks`,
    /// which Chrome replaces with the server copy on its next sync.
    public var bookmarksPath: String { directory + "/Bookmarks" }
    public var accountBookmarksPath: String { directory + "/AccountBookmarks" }

    public var label: String {
        var out = browser.name
        if !directoryName.isEmpty { out += " \(directoryName)" }
        if let displayName, !displayName.isEmpty, displayName != directoryName { out += " (\(displayName))" }
        return out
    }

    /// The file to read when this profile is the sync source.
    public var sourceFile: BookmarkFile.Info? {
        BrowserLocator.chooseBookmarkFile(in: directory, label: label)
    }
}

extension BrowserLocator {

    public static func candidate(named name: String) -> Candidate? {
        chromiumBrowsers.first { $0.name == name.lowercased() }
    }

    /// Profile directories of one browser: every directory holding `Preferences` or a
    /// bookmark file, so a profile that has never saved a bookmark can still be a target.
    public static func chromiumProfiles(_ candidate: Candidate, home homeOverride: String? = nil) -> [ChromiumProfile] {
        let root = home(homeOverride) + "/Library/Application Support/\(candidate.applicationSupportPath)"
        let names = profileDisplayNames(root: root)
        func isProfile(_ dir: String) -> Bool {
            (["Preferences"] + bookmarkFileNames).contains { FileManager.default.fileExists(atPath: "\(dir)/\($0)") }
        }
        if candidate.isFlat {
            return isProfile(root) ? [ChromiumProfile(browser: candidate, directoryName: "", displayName: nil, directory: root)] : []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries.sorted().compactMap { entry in
            guard !nonProfileDirectories.contains(entry) else { return nil }
            let dir = "\(root)/\(entry)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue, isProfile(dir) else { return nil }
            return ChromiumProfile(browser: candidate, directoryName: entry, displayName: names[entry], directory: dir)
        }
    }

    /// `Local State` › `profile` › `info_cache` › `<dir>` › `name`.
    static func profileDisplayNames(root: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/Local State")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (object["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (dir, info) in cache {
            if let name = (info as? [String: Any])?["name"] as? String { out[dir] = name }
        }
        return out
    }

    /// Resolves `--from-profile` / `--to-profile`. Without a name: `Default`, or the only
    /// profile there is.
    public static func chromiumProfile(browser: String, named wanted: String?, home homeOverride: String? = nil) throws -> ChromiumProfile {
        guard let candidate = candidate(named: browser) else {
            throw SyncError.unknownBrowser(browser, known: ["safari"] + chromiumBrowsers.map(\.name))
        }
        let all = chromiumProfiles(candidate, home: homeOverride)
        guard !all.isEmpty else { throw SyncError.noProfiles(candidate.name) }
        let options = all.map { p in p.displayName.map { "\"\(p.directoryName)\" (\($0))" } ?? "\"\(p.directoryName)\"" }
        guard let wanted, !wanted.isEmpty else {
            if let def = all.first(where: { $0.directoryName == "Default" }) ?? (all.count == 1 ? all.first : nil) { return def }
            throw SyncError.ambiguousProfile(candidate.name, options)
        }
        let lower = wanted.lowercased()
        if let m = all.first(where: { $0.directoryName.lowercased() == lower })
            ?? all.first(where: { $0.displayName?.lowercased() == lower })
            ?? all.first(where: { ($0.displayName ?? $0.directoryName).lowercased().contains(lower) }) {
            return m
        }
        throw SyncError.noSuchProfile(candidate.name, wanted, options)
    }

    public static func isRunning(_ candidate: Candidate) -> Bool {
        isRunning(bundleIdentifier: candidate.bundleIdentifier)
    }

    public static let safariBundleIdentifier = "com.apple.Safari"

    public static func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

// MARK: - Undo

/// What a sync changed, written next to every sync so it can be reverted.
///
/// A Safari target records the UUIDs of the top-level items the sync created in
/// `Bookmarks.plist` (removing them removes everything it added, and nothing else — changes
/// made since, including ones iCloud brought in, survive). A Chromium target records the
/// backup taken before writing. `safariDatabase`/`createdIDs` are from the old SafariTabs.db
/// writer and are kept so its logs can still be undone.
public struct SyncUndoLog: Codable {
    public var date: Date
    public var from: String
    public var to: String
    public var safariDatabase: String?
    public var createdIDs: [Int]?
    public var safariPlist: String?
    public var createdUUIDs: [String]?
    public var bookmarksFile: String?
    public var backupFile: String?

    public init(date: Date = Date(), from: String, to: String, safariDatabase: String? = nil, createdIDs: [Int]? = nil,
                safariPlist: String? = nil, createdUUIDs: [String]? = nil, bookmarksFile: String? = nil, backupFile: String? = nil) {
        self.date = date
        self.from = from
        self.to = to
        self.safariDatabase = safariDatabase
        self.createdIDs = createdIDs
        self.safariPlist = safariPlist
        self.createdUUIDs = createdUUIDs
        self.bookmarksFile = bookmarksFile
        self.backupFile = backupFile
    }

    public static func directory(home: String? = nil) -> String {
        BrowserLocator.home(home) + "/Library/Application Support/marksync/undo"
    }

    public static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Saves the log and returns its path.
    @discardableResult
    public func save(home: String? = nil) throws -> String {
        let dir = Self.directory(home: home)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(Self.timestamp(date))-\(from)-to-\(to).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    /// Loads a log by path, or the newest one for `last`.
    public static func load(_ pathOrLast: String, home: String? = nil) throws -> (path: String, log: SyncUndoLog) {
        var path = (pathOrLast as NSString).expandingTildeInPath
        if pathOrLast == "last" {
            let dir = directory(home: home)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
            guard let newest = names.last else { throw SyncError.noUndoLog("in \(dir)") }
            path = "\(dir)/\(newest)"
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw SyncError.noUndoLog("at \(path)") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (path, try decoder.decode(SyncUndoLog.self, from: data))
    }
}
