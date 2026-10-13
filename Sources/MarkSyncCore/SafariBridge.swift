import Foundation
import ObjectiveC

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Objective-C runtime plumbing

/// Thin, typed wrappers over `objc_msgSend` for calling into private frameworks that have
/// no Swift/`#import`able headers.
///
/// Design notes (learned the hard way while reversing WebBookmarks):
/// * `NSInvocation` and `NSMethodSignature` are unavailable in Swift, so every call has to
///   go through `unsafeBitCast`ed `@convention(c)` closures with the exact ABI of the
///   selector — types taken from `method_getTypeEncoding`.
/// * For a *class object* receiver, `object_getClass` yields the metaclass, which is what
///   `class_getInstanceMethod` expects for class methods. That single lookup path handles
///   both instance and class methods.
/// * Framework handles are kept alive in `loadedFrameworks` for the process lifetime —
///   dlopen'ing inside a function body can deadlock the runtime before the Objective-C
///   class map is initialised.
enum ObjC {
    private static let libobjc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW)

    @inline(never)
    static func imp(of receiver: AnyObject, _ name: String) -> IMP? {
        let sel = NSSelectorFromString(name)
        let cls: AnyClass = object_isClass(receiver) ? object_getClass(receiver)! : object_getClass(receiver)!
        if let m = class_getInstanceMethod(cls, sel) { return method_getImplementation(m) }
        if let m = class_getClassMethod(cls, sel) { return method_getImplementation(m) }
        return nil
    }

    static func responds(_ receiver: AnyObject, _ name: String) -> Bool {
        imp(of: receiver, name) != nil
    }

    static func encoding(of receiver: AnyObject, _ name: String) -> String? {
        let sel = NSSelectorFromString(name)
        let cls: AnyClass = object_isClass(receiver) ? object_getClass(receiver)! : object_getClass(receiver)!
        if let m = class_getInstanceMethod(cls, sel) { return String(cString: method_getTypeEncoding(m)!) }
        if let m = class_getClassMethod(cls, sel) { return String(cString: method_getTypeEncoding(m)!) }
        return nil
    }

    static func call(_ receiver: AnyObject, _ name: String) -> AnyObject? {
        guard let i = imp(of: receiver, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(i, to: F.self)(receiver, NSSelectorFromString(name))?.takeUnretainedValue()
    }

    static func call(_ receiver: AnyObject, _ name: String, _ a: AnyObject?) -> AnyObject? {
        guard let i = imp(of: receiver, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(i, to: F.self)(receiver, NSSelectorFromString(name), a)?.takeUnretainedValue()
    }

    static func call(_ receiver: AnyObject, _ name: String, _ a: AnyObject?, _ b: AnyObject?) -> AnyObject? {
        guard let i = imp(of: receiver, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(i, to: F.self)(receiver, NSSelectorFromString(name), a, b)?.takeUnretainedValue()
    }

    static func call(_ receiver: AnyObject, _ name: String, int a: Int) -> AnyObject? {
        guard let i = imp(of: receiver, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<AnyObject>?
        return unsafeBitCast(i, to: F.self)(receiver, NSSelectorFromString(name), a)?.takeUnretainedValue()
    }

    static func call(_ receiver: AnyObject, _ name: String, int a: Int, int b: Int) -> AnyObject? {
        guard let i = imp(of: receiver, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, Int, Int) -> Unmanaged<AnyObject>?
        return unsafeBitCast(i, to: F.self)(receiver, NSSelectorFromString(name), a, b)?.takeUnretainedValue()
    }

    static func callInt(_ receiver: AnyObject, _ name: String) -> Int? {
        guard let i = imp(of: receiver, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(i, to: F.self)(receiver, NSSelectorFromString(name))
    }

    static func callBool(_ receiver: AnyObject, _ name: String) -> Bool? {
        guard let i = imp(of: receiver, name) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(i, to: F.self)(receiver, NSSelectorFromString(name))
    }

    static func string(_ receiver: AnyObject, _ name: String) -> String? {
        call(receiver, name) as? String
    }

    static func `class`(_ name: String) -> AnyObject? {
        NSClassFromString(name) as AnyObject?
    }

    /// Reads a global `NSString * const` exported by a framework.
    static func globalString(_ handle: UnsafeMutableRawPointer?, _ symbol: String) -> String? {
        guard let handle, let p = dlsym(handle, symbol) else { return nil }
        // For these globals the pointer must be reinterpreted as an `AnyObject?` slot …
        let viaObject = p.assumingMemoryBound(to: AnyObject?.self).pointee as? String
        if let viaObject, !viaObject.isEmpty { return viaObject }
        // … but a few are laid out as a direct char pointer.
        return String(cString: p.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee)
    }
}

// MARK: - WebBookmarks bridge

/// Reverse-engineered bridge to `/System/Library/PrivateFrameworks/WebBookmarks.framework`.
///
/// Everything here was recovered by inspecting the framework's Objective-C classes,
/// method type encodings and the on-disk schema. Two facts shape the design:
///
/// 1. **The bookmarks live in a tab database.** Safari 17+/26 stores bookmarks, tab groups,
///    profiles and windows in one SQLite file,
///    `~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db`
///    (the legacy `~/Library/Safari/Bookmarks.db` no longer exists). `WebBookmarkCollection`
///    is the abstraction over it.
/// 2. **Profiles are `bookmarks` rows.** A profile is a hidden folder carrying a
///    `com.apple.Bookmark`/`DateAdded` extra-attribute blob; "Local"/"Private" folders hold
///    the actual profile bookmarks. The bookmarks bar is a normal folder with
///    `special_id = 1` (`BookmarksBarSpecialID`), the reading list is `special_id = 3`.
public final class SafariBridge {

    public enum BridgeError: Error, CustomStringConvertible {
        case frameworkUnavailable(String)
        case classUnavailable(String)
        case collectionUnavailable(String)
        case mergeFailed(String?)

        public var description: String {
            switch self {
            case .frameworkUnavailable(let p): return "could not load WebBookmarks framework at \(p)"
            case .classUnavailable(let n): return "private class \(n) is not present in this OS build"
            case .collectionUnavailable(let p): return "could not open a WebBookmarkCollection at \(p)"
            case .mergeFailed(let m): return "WebBookmarks refused the merge: \(m ?? "unknown error")"
            }
        }
    }

    public struct Profile: Equatable, Sendable {
        public var id: Int
        public var title: String
        public var uuid: String?
        public var parentID: Int
    }

    public static let frameworkPath = "/System/Library/PrivateFrameworks/WebBookmarks.framework/WebBookmarks"
    private static let dependencyPaths = [
        "/System/Library/PrivateFrameworks/SafariShared.framework/SafariShared",
        "/System/Library/PrivateFrameworks/SafariCore.framework/SafariCore",
        "/System/Library/PrivateFrameworks/SafariFoundation.framework/SafariFoundation",
        "/System/Library/PrivateFrameworks/SafariSharedUI.framework/SafariSharedUI",
    ]

    private static var handles: [UnsafeMutableRawPointer] = []
    private static var didLoad = false

    /// Loads WebBookmarks and its siblings once, for the process lifetime.
    @discardableResult
    public static func loadFramework() throws -> UnsafeMutableRawPointer {
        if didLoad, let first = handles.first { return first }
        guard let main = dlopen(frameworkPath, RTLD_NOW) else {
            throw BridgeError.frameworkUnavailable(frameworkPath)
        }
        for path in dependencyPaths { _ = dlopen(path, RTLD_NOW) }
        handles = [main]
        didLoad = true
        return main
    }

    public static var isAvailable: Bool {
        (try? loadFramework()) != nil && NSClassFromString("WebBookmarkCollection") != nil
    }

    // MARK: Constants recovered from the framework

    /// `BookmarksBarSpecialID` = 0x2_0000_0001 (the low 32 bits are what the API takes).
    public static let specialIDBookmarksBar = 1
    /// `BookmarksReadingListSpecialID` = 0x4_0000_0003.
    public static let specialIDReadingList = 3
    public static let specialIDRoot = 0
    /// `subtype` value of the legacy pre-profile bookmarks-bar folder.
    public static let libriFolderSubtype = 2

    public struct Handle {
        public let collection: AnyObject
        public let databasePath: String
        public init(collection: AnyObject, databasePath: String) {
            self.collection = collection
            self.databasePath = databasePath
        }
    }

    // MARK: Opening

    /// Opens the live Safari bookmark collection.
    ///
    /// `WBCollectionConfiguration.safariBookmarkCollectionConfiguration` populates its
    /// `databasePath` only when the process is in Safari's container — we verified that
    /// `databasePath` comes back `nil` for every non-tab configuration outside the sandbox,
    /// while `inMemoryBookmarkCollectionConfiguration` yields `":memory:"`. So we build the
    /// path ourselves and open with `initWithPath:migratingBookmarksPlist:syncAnchorPlist:`.
    public static func safariDatabasePath(home: String? = nil) -> String {
        let base = home ?? realHomeDirectory()
        return base + "/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db"
    }

    /// The legacy location, still used by older Safari releases. Returns it only if it exists.
    public static func legacySafariDatabasePath(home: String? = nil) -> String? {
        let base = home ?? realHomeDirectory()
        let candidates = [
            base + "/Library/Safari/Bookmarks.db",
            base + "/Library/Containers/com.apple.Safari/Data/Library/Safari/Bookmarks.db",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return nil
    }

    public static func openSafariCollection(readOnly: Bool = true) throws -> Handle {
        let modern = safariDatabasePath()
        let path = FileManager.default.fileExists(atPath: modern) ? modern : (legacySafariDatabasePath() ?? modern)
        return try open(path: path)
    }

    public static func open(path: String) throws -> Handle {
        try loadFramework()
        guard let collectionClass = ObjC.class("WebBookmarkCollection") else {
            throw BridgeError.classUnavailable("WebBookmarkCollection")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw BridgeError.collectionUnavailable(path)
        }
        guard let alloc = ObjC.call(collectionClass, "alloc") else {
            throw BridgeError.collectionUnavailable(path)
        }
        // -initWithPath:migratingBookmarksPlist:syncAnchorPlist:
        guard let collection = ObjC.call(
            alloc,
            "initWithPath:migratingBookmarksPlist:syncAnchorPlist:",
            path as NSString,
            nil
        ) else {
            throw BridgeError.collectionUnavailable(path)
        }
        return Handle(collection: collection, databasePath: path)
    }

    /// Opens a collection backed by a configuration object (needed for in-memory use).
    public static func open(configuration selector: String) throws -> AnyObject {
        try loadFramework()
        guard let configClass = ObjC.class("WBCollectionConfiguration"),
              let collectionClass = ObjC.class("WebBookmarkCollection"),
              let configuration = ObjC.call(configClass, selector) else {
            throw BridgeError.classUnavailable("WBCollectionConfiguration.\(selector)")
        }
        guard let collection = ObjC.call(collectionClass, "collectionWithConfiguration:", configuration) else {
            throw BridgeError.collectionUnavailable(selector)
        }
        return collection
    }

    // MARK: Reading

    public struct RawBookmark {
        public var id: Int
        public var parentID: Int
        public var specialID: Int
        public var title: String
        public var address: String
        public var isFolder: Bool
        public var isHidden: Bool
        public var subtype: Int
        public var dateAdded: Date?
        public var annotation: String?
    }

    public static func bookmarksBarID(_ handle: Handle) -> Int? {
        guard let bar = ObjC.call(handle.collection, "bookmarkWithSpecialID:", int: specialIDBookmarksBar) else { return nil }
        return ObjC.callInt(bar, "identifier")
    }

    public static func readingListID(_ handle: Handle) -> Int? {
        guard let node = ObjC.call(handle.collection, "bookmarkWithSpecialID:", int: specialIDReadingList) else { return nil }
        return ObjC.callInt(node, "identifier")
    }

    public static func rootID(_ handle: Handle) -> Int? {
        guard let root = ObjC.call(handle.collection, "rootBookmark") else { return nil }
        return ObjC.callInt(root, "identifier")
    }

    public static func bookmark(_ handle: Handle, id: Int) -> RawBookmark? {
        guard let b = ObjC.call(handle.collection, "bookmarkWithID:", int: id) else { return nil }
        return raw(b)
    }

    /// The raw `WebBookmark` object, for callers that need fields this bridge does not model.
    public static func bookmarkObject(_ handle: Handle, id: Int) -> AnyObject? {
        ObjC.call(handle.collection, "bookmarkWithID:", int: id)
    }

    /// Escape hatch for calling a private selector on an object obtained from this bridge.
    public static func call(_ object: AnyObject, _ selector: String) -> AnyObject? {
        ObjC.call(object, selector)
    }

    public static func children(_ handle: Handle, of id: Int, includeHidden: Bool = true) -> [RawBookmark] {
        // `-listWithID:` hides hidden rows — and *every* profile folder and system folder under
        // the collection root is hidden, so it returns nothing for id 0. The explicit
        // `-listWithID:skipOffset:includeHidden:` variant is required to see them.
        let selector = "listWithID:skipOffset:includeHidden:"
        typealias F = @convention(c) (AnyObject, Selector, Int, UInt32, Bool) -> Unmanaged<AnyObject>?
        guard let i = ObjC.imp(of: handle.collection, selector) else { return [] }
        guard let list = unsafeBitCast(i, to: F.self)(
            handle.collection, NSSelectorFromString(selector), id, 0, includeHidden
        )?.takeUnretainedValue() else { return [] }
        let count = ObjC.callInt(list, "bookmarkCount") ?? 0
        var out: [RawBookmark] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            autoreleasepool {
                // -bookmarkAtIndex:skipDecodingSyncData:
                guard let b = ObjC.call(list, "bookmarkAtIndex:skipDecodingSyncData:", int: i, int: 0) else { return }
                out.append(raw(b))
            }
        }
        return out
    }

    private static func raw(_ b: AnyObject) -> RawBookmark {
        let dateAdded: Date? = {
            guard let d = ObjC.call(b, "dateAdded") else { return nil }
            return d as? Date
        }()
        var annotation: String?
        if let extra = ObjC.call(b, "extraAttributes") as? [String: Any],
           let bookmark = extra["com.apple.Bookmark"] as? [String: Any] {
            annotation = bookmark["Description"] as? String
        }
        return RawBookmark(
            id: ObjC.callInt(b, "identifier") ?? -1,
            parentID: ObjC.callInt(b, "parentID") ?? -1,
            specialID: 0,
            title: ObjC.string(b, "title") ?? "",
            address: ObjC.string(b, "address") ?? "",
            isFolder: ObjC.callBool(b, "isFolder") ?? false,
            isHidden: ObjC.callBool(b, "isHidden") ?? false,
            subtype: ObjC.callInt(b, "subtype") ?? 0,
            dateAdded: dateAdded,
            annotation: annotation
        )
    }

    public static func profiles(_ handle: Handle) -> [Profile] {
        guard let root = rootID(handle) else { return [] }
        var out: [Profile] = []
        for child in children(handle, of: root) {
            // A profile is a hidden folder with a DateAdded extra attribute that is not one of
            // the well-known special folders (pinned / recently closed / reading list …).
            guard child.isFolder, child.isHidden, child.subtype == 0 else { continue }
            guard child.specialID == 0 else { continue }
            guard !["pinned", "privatePinned", "recentlyClosed", "Recovered"].contains(child.title) else { continue }
            guard ObjC.call(handle.collection, "bookmarkWithID:", int: child.id) != nil else { continue }
            out.append(Profile(id: child.id, title: child.title, uuid: nil, parentID: child.parentID))
        }
        return out
    }

    /// True when the directory holding `path` is writable by this process.
    public static func isWritable(_ handle: Handle) -> Bool {
        FileManager.default.isWritableFile(atPath: handle.databasePath)
    }

    // MARK: Writing

    public struct ImportRequest {
        /// Destination folder id inside the collection.
        public var parentID: Int
        /// Title of the container folder created for this import.
        public var containerTitle: String
        /// Nodes to import; folders are created recursively.
        public var nodes: [BookmarkNode]
        public var reuseExistingContainer: Bool

        public init(parentID: Int, containerTitle: String, nodes: [BookmarkNode], reuseExistingContainer: Bool = true) {
            self.parentID = parentID
            self.containerTitle = containerTitle
            self.nodes = nodes
            self.reuseExistingContainer = reuseExistingContainer
        }
    }

    public struct ImportResult {
        public var folderCount: Int
        public var linkCount: Int
        public var containerID: Int
        public var createdContainer: Bool
        public var destination: String
    }

    /// Creates bookmarks directly through the WebBookmarks API.
    ///
    /// We deliberately do *not* use `-mergeWithBookmarksDictionary:clearHidden:clearSyncData:error:`
    /// for the normal path: it always appends its top-level children to the collection root,
    /// which is invisible in Safari's UI (Safari only shows the bookmarks bar, the reading
    /// list and profile folders). Using `WebBookmark` + `-saveBookmark:` lets us choose the
    /// destination folder and gives us per-item rollback.
    public static func importNodes(_ handle: Handle, request: ImportRequest) throws -> ImportResult {
        try loadFramework()
        guard let bookmarkClass = ObjC.class("WebBookmark") else {
            throw BridgeError.classUnavailable("WebBookmark")
        }

        var containerID: Int
        var created = false
        if request.reuseExistingContainer,
           let existing = children(handle, of: request.parentID).first(where: {
               $0.isFolder && $0.title == request.containerTitle
           }) {
            containerID = existing.id
        } else {
            guard let folder = newFolder(bookmarkClass: bookmarkClass, title: request.containerTitle, parentID: request.parentID),
                  save(handle, folder) else {
                throw BridgeError.mergeFailed("could not create the container folder")
            }
            containerID = ObjC.callInt(folder, "identifier") ?? -1
            created = true
        }

        let inserted: InsertResult
        do {
            inserted = try insertNodes(handle, request.nodes, into: containerID)
        } catch {
            // Roll back the whole container so a failed import leaves no half-written tree.
            if created, let folder = ObjC.call(handle.collection, "bookmarkWithID:", int: containerID) {
                delete(handle, folder)
            }
            throw BridgeError.mergeFailed("inserting bookmarks failed; rolled back the container folder")
        }

        return ImportResult(
            folderCount: inserted.folderCount,
            linkCount: inserted.linkCount,
            containerID: containerID,
            createdContainer: created,
            destination: request.containerTitle
        )
    }

    public struct InsertResult {
        /// Ids of the items created directly in the target folder. Deleting them removes
        /// everything the call added.
        public var createdIDs: [Int] = []
        public var folderCount = 0
        public var linkCount = 0
    }

    /// Appends `nodes` (recursively) to the existing folder `parentID`.
    ///
    /// All or nothing: if any item fails, every item this call created is deleted again.
    public static func insertNodes(_ handle: Handle, _ nodes: [BookmarkNode], into parentID: Int) throws -> InsertResult {
        try loadFramework()
        guard let bookmarkClass = ObjC.class("WebBookmark") else {
            throw BridgeError.classUnavailable("WebBookmark")
        }
        var result = InsertResult()

        func insert(_ nodes: [BookmarkNode], into parent: Int, topLevel: Bool) -> Bool {
            for node in nodes {
                switch node.kind {
                case .folder:
                    guard let folder = newFolder(bookmarkClass: bookmarkClass, title: node.title, parentID: parent),
                          save(handle, folder) else { return false }
                    let childID = ObjC.callInt(folder, "identifier") ?? -1
                    if topLevel { result.createdIDs.append(childID) }
                    result.folderCount += 1
                    guard insert(node.children, into: childID, topLevel: false) else { return false }
                case .link:
                    guard let bm = newLink(
                        bookmarkClass: bookmarkClass,
                        title: node.title,
                        address: node.href,
                        parentID: parent,
                        dateAdded: node.dateAdded
                    ), save(handle, bm) else { return false }
                    if topLevel { result.createdIDs.append(ObjC.callInt(bm, "identifier") ?? -1) }
                    result.linkCount += 1
                }
            }
            return true
        }

        guard insert(nodes, into: parentID, topLevel: true) else {
            for id in result.createdIDs.reversed() {
                if let b = ObjC.call(handle.collection, "bookmarkWithID:", int: id) { delete(handle, b) }
            }
            throw BridgeError.mergeFailed("inserting into folder #\(parentID) failed; removed the \(result.createdIDs.count) item(s) already added")
        }
        return result
    }

    private static func newFolder(bookmarkClass: AnyObject, title: String, parentID: Int) -> AnyObject? {
        guard let alloc = ObjC.call(bookmarkClass, "alloc") else { return nil }
        // -initFolderWithParentID:subtype:collectionType: takes no title, so the label has to be
        // set separately. subtype 0 is a plain user folder; 2 is the legacy "all bookmarks"
        // container and must not be used for folders we create.
        guard let folder = ObjC.call(alloc, "initFolderWithParentID:subtype:collectionType:", int: parentID, int: 0) else {
            return nil
        }
        setTitle(folder, title)
        return folder
    }

    @discardableResult
    static func setTitle(_ bookmark: AnyObject, _ title: String) -> Bool {
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        guard let i = ObjC.imp(of: bookmark, "setTitle:") else { return false }
        unsafeBitCast(i, to: F.self)(bookmark, NSSelectorFromString("setTitle:"), title as NSString)
        return true
    }

    private static func newLink(bookmarkClass: AnyObject, title: String, address: String, parentID: Int, dateAdded: Date?) -> AnyObject? {
        guard let alloc = ObjC.call(bookmarkClass, "alloc") else { return nil }
        // -initWithTitle:address:parentID:folder:collectionType:
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, Int, Bool, Int) -> Unmanaged<AnyObject>?
        guard let i = ObjC.imp(of: alloc, "initWithTitle:address:parentID:folder:collectionType:") else { return nil }
        guard let bm = unsafeBitCast(i, to: F.self)(
            alloc,
            NSSelectorFromString("initWithTitle:address:parentID:folder:collectionType:"),
            title as NSString, address as NSString, parentID, false, 0
        )?.takeUnretainedValue() else { return nil }

        // The initializer does not always stick the label, so set it explicitly.
        setTitle(bm, title)

        if let dateAdded {
            // -setDateAdded: keeps imported timestamps instead of "now".
            typealias S = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            if let si = ObjC.imp(of: bm, "setDateAdded:") {
                unsafeBitCast(si, to: S.self)(bm, NSSelectorFromString("setDateAdded:"), dateAdded as NSDate)
            }
        }
        return bm
    }

    @discardableResult
    private static func save(_ handle: Handle, _ bookmark: AnyObject) -> Bool {
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard let i = ObjC.imp(of: handle.collection, "saveBookmark:") else { return false }
        return unsafeBitCast(i, to: F.self)(handle.collection, NSSelectorFromString("saveBookmark:"), bookmark)
    }

    @discardableResult
    private static func delete(_ handle: Handle, _ bookmark: AnyObject) -> Bool {
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard let i = ObjC.imp(of: handle.collection, "deleteBookmark:") else { return false }
        return unsafeBitCast(i, to: F.self)(handle.collection, NSSelectorFromString("deleteBookmark:"), bookmark)
    }

    /// Deletes a bookmark (or a whole folder subtree) by id.
    public static func deleteFolder(_ handle: Handle, id: Int) throws {
        try loadFramework()
        guard let bookmark = ObjC.call(handle.collection, "bookmarkWithID:", int: id) else {
            throw BridgeError.mergeFailed("no bookmark #\(id) in \(handle.databasePath)")
        }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard let i = ObjC.imp(of: handle.collection, "deleteBookmark:") else {
            throw BridgeError.mergeFailed("WebBookmarkCollection does not implement -deleteBookmark:")
        }
        let ok = unsafeBitCast(i, to: F.self)(handle.collection, NSSelectorFromString("deleteBookmark:"), bookmark)
        guard ok else { throw BridgeError.mergeFailed("WebBookmarks refused to delete #\(id)") }
    }

    /// Asks a running Safari to reload its bookmark model.
    ///
    /// `WebBookmarksDidReloadDistributedNotification` is a distributed notification, so a
    /// plain `DistributedNotificationCenter.post` reaches Safari from an unsandboxed helper.
    public static func notifySafariToReload() {
        guard let handle = try? loadFramework() else { return }
        guard let name = ObjC.globalString(handle, "WebBookmarksDidReloadDistributedNotification") else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    /// The undecorated method list of a private class — used by `marksync inspect`.
    public static func dumpMethods(of className: String) -> [String] {
        guard let cls = NSClassFromString(className) else { return [] }
        var lines: [String] = []
        for (target, sign) in [(cls, "-"), (object_getClass(cls)!, "+")] {
            var count: UInt32 = 0
            guard let list = class_copyMethodList(target, &count) else { continue }
            defer { free(list) }
            for i in 0..<Int(count) {
                let name = NSStringFromSelector(method_getName(list[i]))
                let enc = String(cString: method_getTypeEncoding(list[i])!)
                lines.append("\(sign) \(name)  |\(enc)")
            }
        }
        return lines.sorted()
    }

    /// Resolves `~` against the *real* account home.
    ///
    /// macOS keeps `HOME` pinned to the app container for sandboxed processes, and `NSHomeDirectory()`
    /// inside an XPC service reports the container too, so reading either can point at the wrong
    /// place. `getpwuid` always reports the account's home directory.
    public static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}
