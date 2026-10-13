import Foundation
import MarkSyncCore

/// Slot mapping and the additive merge behind `marksync sync`.
enum SyncSuite {

    static func target(_ document: ChromiumDocument) -> [BookmarkSlot: BookmarkMerge.TargetFolder] {
        document.mergeTarget()
    }

    /// Applies a plan to a Chromium document, the way the CLI does.
    static func apply(_ plan: BookmarkMerge.Plan, to document: ChromiumDocument) throws {
        for insertion in plan.insertions { try document.insert(insertion.nodes, into: insertion.parentRef) }
    }

    static let all: [TestCase] = [
        TestCase("Chromium roots map onto slots") {
            let slots = SlottedBookmarks(try ChromiumBookmarks.parse(Data(chromiumFixture.utf8)))
            expectEqual(slots.children(.bar).map(\.title), ["Example", "Folder"])
            expectEqual(slots.children(.other).map(\.title), ["Other one"])
            expectEqual(slots.children(.mobile).count, 0)
            expectEqual(slots.titles[.bar], "Bookmarks bar")
        },

        TestCase("unknown roots become folders in other; reading list is left out") {
            let tree = BookmarkTree(source: "safari", roots: [
                .init(id: "bookmark_bar", title: "Bookmarks Bar", node: .folder("Bookmarks Bar", children: [.link("A", "https://a.example/")])),
                .init(id: "profile-44", title: "Default", node: .folder("Default", children: [.link("B", "https://b.example/")])),
                .init(id: "reading_list", title: "Reading List", node: .folder("Reading List", children: [.link("R", "https://r.example/")])),
            ])
            let slots = SlottedBookmarks(tree)
            expectEqual(slots.children(.bar).count, 1)
            expectEqual(slots.children(.other).map(\.title), ["Default"])
            expectEqual(slots.linkCount, 2)
        },

        TestCase("merge keeps the bar on the bar and reuses folders by name") {
            let source = SlottedBookmarks(nodes: [
                .bar: [
                    .link("Example", "HTTPS://Example.com"),                 // already there, different spelling
                    .folder("Folder", children: [.link("New nested", "https://new.example/")]),
                    .link("Fresh", "https://fresh.example/"),
                ],
                .other: [.folder("Brand new", children: [.link("X", "https://x.example/")])],
            ])
            let document = try ChromiumDocument(data: Data(chromiumFixture.utf8))
            let plan = BookmarkMerge.plan(source: source, target: target(document))
            expectEqual(plan.skipped, 1)
            expectEqual(plan.linkCount, 3)
            expectEqual(plan.folderCount, 1, "only 'Brand new' is created; 'Folder' exists")
            let byPath = Dictionary(uniqueKeysWithValues: plan.insertions.map { ($0.path, $0.nodes.map(\.title)) })
            expectEqual(byPath["bar"], ["Fresh"])
            expectEqual(byPath["bar › Folder"], ["New nested"])
            expectEqual(byPath["other"], ["Brand new"])
            expectEqual(plan.insertions.first { $0.path == "bar › Folder" }?.parentRef, "6", "existing Chromium folder id")
        },

        TestCase("running the same sync twice adds nothing the second time") {
            let source = SlottedBookmarks(nodes: [
                .bar: [.link("A", "https://a.example/"), .folder("F", children: [.link("B", "https://b.example/")])],
                .mobile: [.link("M", "https://m.example/")],
            ], titles: [.mobile: "移动收藏夹"])
            let document = ChromiumDocument()
            try apply(BookmarkMerge.plan(source: source, target: target(document)), to: document)
            expectEqual(try document.tree().linkCount, 3)
            let again = BookmarkMerge.plan(source: source, target: target(document))
            expectTrue(again.isEmpty)
            expectEqual(again.skipped, 3)
        },

        TestCase("a slot the target lacks is folded into other, once") {
            let source = SlottedBookmarks(nodes: [.mobile: [.link("M", "https://m.example/")]], titles: [.mobile: "移动收藏夹"])
            var slots = target(ChromiumDocument())
            slots[.mobile] = nil   // like Safari
            let plan = BookmarkMerge.plan(source: source, target: slots)
            expectEqual(plan.folded, [.mobile])
            expectEqual(plan.insertions.first?.path, "other")
            expectEqual(plan.insertions.first?.nodes.first?.title, "移动收藏夹")

            // Second run: the folder now exists in `other` and is merged into, not duplicated.
            var other = try unwrap(slots[.other])
            other.folders.append(.init(ref: "99", title: "移动收藏夹", urls: ["https://m.example/"]))
            slots[.other] = other
            expectTrue(BookmarkMerge.plan(source: source, target: slots).isEmpty)
        },

        TestCase("duplicates inside the source are added once") {
            let source = SlottedBookmarks(nodes: [.other: [
                .link("A", "https://a.example/"),
                .folder("F", children: [.link("A again", "https://a.example")]),
            ]])
            let plan = BookmarkMerge.plan(source: source, target: target(ChromiumDocument()))
            expectEqual(plan.linkCount, 1)
            expectEqual(plan.skipped, 1)
        },

        TestCase("URL normalisation") {
            expectEqual(BookmarkMerge.normalize("HTTPS://Example.COM/"), BookmarkMerge.normalize("https://example.com"))
            expectTrue(BookmarkMerge.normalize("https://example.com/A") != BookmarkMerge.normalize("https://example.com/a"), "paths stay case-sensitive")
            expectEqual(BookmarkMerge.normalize(" javascript:void(0) "), "javascript:void(0)")
        },
    ]
}

/// The Chromium file a sync writes has to be one Chrome accepts.
enum ChromiumDocumentSuite {

    static func allIDs(_ data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let roots = object["roots"] as! [String: Any]
        var ids: [String] = []
        func visit(_ node: [String: Any]) {
            ids.append(node["id"] as? String ?? "")
            for case let child as [String: Any] in node["children"] as? [Any] ?? [] { visit(child) }
        }
        for key in ChromiumDocument.rootKeys { visit(roots[key] as! [String: Any]) }
        return ids
    }

    static let all: [TestCase] = [
        TestCase("new file has the three permanent roots and integer ids") {
            let data = try ChromiumDocument().data()
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let roots = object["roots"] as! [String: Any]
            expectEqual(Set(roots.keys), ["bookmark_bar", "other", "synced"])
            expectEqual(try allIDs(data), ["1", "2", "3"])
            expectEqual((roots["bookmark_bar"] as! [String: Any])["guid"] as? String, "0bc5d13f-2cba-5d74-951f-3f233fe6c908")
        },

        TestCase("insert keeps existing fields and allocates fresh ids") {
            let document = try ChromiumDocument(data: Data(chromiumFixture.utf8))
            try document.insert([.folder("New", children: [.link("N", "https://n.example/")])], into: "1")
            let data = try document.data()
            let ids = try allIDs(data)
            expectEqual(ids.count, Set(ids).count, "ids are unique")
            expectTrue(ids.allSatisfy { Int64($0) != nil }, "ids are integers")
            expectTrue(ids.contains("9") && ids.contains("10"), "new ids continue after the highest existing one (8)")
            let text = String(decoding: data, as: UTF8.self)
            expectTrue(text.contains("00000000-0000-0000-0000-000000000001"), "existing guid preserved")
            expectTrue(text.contains("with a note"), "existing meta_info preserved")
            expectTrue(text.contains("https://n.example/"), "slashes are not escaped")
            expectEqual(try ChromiumBookmarks.parse(data).linkCount, 4)
        },

        TestCase("checksum follows Chrome's algorithm and tracks edits") {
            let document = ChromiumDocument()
            try document.insert([.link("é", "https://a.example/")], into: "1")
            // Recompute independently: id, UTF-16LE title, type, url — roots in file order.
            var expected = [UInt8]()
            func add(_ s: String) { expected += Array(s.utf8) }
            func addTitle(_ s: String) { for u in s.utf16 { expected += [UInt8(u & 0xFF), UInt8(u >> 8)] } }
            add("1"); addTitle("Bookmarks bar"); add("folder")
            add("4"); addTitle("é"); add("url"); add("https://a.example/")
            add("2"); addTitle("Other bookmarks"); add("folder")
            add("3"); addTitle("Mobile bookmarks"); add("folder")
            let md5 = Process()
            md5.executableURL = URL(fileURLWithPath: "/sbin/md5")
            md5.arguments = ["-q"]
            let input = Pipe(), output = Pipe()
            md5.standardInput = input
            md5.standardOutput = output
            try md5.run()
            input.fileHandleForWriting.write(Data(expected))
            input.fileHandleForWriting.closeFile()
            md5.waitUntilExit()
            let reference = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            expectEqual(document.computeChecksum(), reference)

            let before = document.computeChecksum()
            try document.insert([.link("b", "https://b.example/")], into: "2")
            expectTrue(document.computeChecksum() != before)
        },

        TestCase("export of a Safari tree is a loadable Chromium file") {
            let tree = BookmarkTree(source: "safari", roots: [
                .init(id: "bookmark_bar", title: "Bookmarks Bar", node: .folder("Bookmarks Bar", children: [.link("A", "https://a.example/")])),
                .init(id: "profile-44", title: "Default", node: .folder("Default", children: [.link("B", "https://b.example/")])),
            ])
            let data = try ChromiumBookmarks.write(tree)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            expectEqual(Set((object["roots"] as! [String: Any]).keys), ["bookmark_bar", "other", "synced"])
            expectTrue(try allIDs(data).allSatisfy { Int64($0) != nil })
            let parsed = try ChromiumBookmarks.parse(data)
            expectEqual(parsed.roots.first { $0.id == "bookmark_bar" }?.node.children.map(\.title), ["A"])
            expectEqual(parsed.roots.first { $0.id == "other" }?.node.children.map(\.title), ["Default"])
        },
    ]
}

/// Profile discovery for sync targets, against a fake home directory.
enum ChromiumProfileSuite {
    static let all: [TestCase] = [
        TestCase("finds profiles by directory or display name") {
            let home = try BrowserLocatorSuite.makeFakeHome()
            let base = home + "/Library/Application Support/Google/Chrome"
            // A profile with no bookmarks yet is still a valid target.
            try FileManager.default.createDirectory(atPath: base + "/Profile 7", withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: base + "/Profile 7/Preferences"))
            try Data(#"{"profile":{"info_cache":{"Profile 7":{"name":"工作"}}}}"#.utf8)
                .write(to: URL(fileURLWithPath: base + "/Local State"))

            let all = BrowserLocator.chromiumProfiles(BrowserLocator.candidate(named: "chrome")!, home: home)
            expectEqual(all.map(\.directoryName), ["Default", "Profile 11", "Profile 3", "Profile 7"])
            expectEqual(try BrowserLocator.chromiumProfile(browser: "chrome", named: nil, home: home).directoryName, "Default")
            expectEqual(try BrowserLocator.chromiumProfile(browser: "chrome", named: "工作", home: home).directoryName, "Profile 7")
            expectEqual(try BrowserLocator.chromiumProfile(browser: "chrome", named: "profile 3", home: home).directoryName, "Profile 3")
            expectEqual(try BrowserLocator.chromiumProfile(browser: "chrome", named: "Profile 7", home: home).label, "chrome Profile 7 (工作)")
            expectThrows { _ = try BrowserLocator.chromiumProfile(browser: "chrome", named: "nope", home: home) }
            expectThrows { _ = try BrowserLocator.chromiumProfile(browser: "netscape", named: nil, home: home) }
        },

    ]
}

/// Safari's real store, `Bookmarks.plist`, as a sync source and target.
enum SafariPlistSuite {

    /// Shaped like a real file: special folders, a History proxy, iCloud `Sync` metadata on an
    /// existing item, and a user folder at the sidebar's top level.
    static func fixture() throws -> Data {
        func leaf(_ title: String, _ url: String, sync: Bool = false) -> [String: Any] {
            var d: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": UUID().uuidString,
                                    "URLString": url, "URIDictionary": ["title": title]]
            if sync { d["Sync"] = ["ServerID": "abc", "Data": Data([1, 2, 3])] }
            return d
        }
        func list(_ title: String, _ children: [[String: Any]], uuid: String = UUID().uuidString) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": uuid, "Title": title, "Children": children]
        }
        let root: [String: Any] = [
            "Title": "", "WebBookmarkFileVersion": 1, "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": "ROOT-UUID",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History"],
                list("BookmarksBar", [leaf("Apple", "https://www.apple.com/", sync: true), list("工具", [leaf("T", "https://t.example/")])], uuid: "BAR-UUID"),
                list("BookmarksMenu", []),
                list("com.apple.ReadingList", [leaf("Later", "https://later.example/")]),
                list("读书", [leaf("豆瓣", "https://book.douban.com/")]),
            ],
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    static let all: [TestCase] = [
        TestCase("reads Favorites as the bar and the sidebar as other") {
            let plist = try SafariBookmarksPlist(data: try fixture())
            let slots = plist.syncSource()
            expectEqual(slots.children(.bar).map(\.title), ["Apple", "工具"])
            expectEqual(slots.children(.other).map(\.title), ["读书"], "reading list, menu and proxies are not sidebar items")
            let target = plist.mergeTarget()
            expectEqual(target[.bar]?.ref, "BAR-UUID")
            expectEqual(target[.other]?.ref, SafariBookmarksPlist.rootRef)
            expectEqual(target[.other]?.folders.map(\.title), ["读书"], "special folders are never merge targets")
            expectNil(target[.mobile])
        },

        TestCase("sync into Safari appends, keeps iCloud metadata, and undoes by UUID") {
            let plist = try SafariBookmarksPlist(data: try fixture())
            let source = SlottedBookmarks(try ChromiumBookmarks.parse(Data(chromiumFixture.utf8)))
            let plan = BookmarkMerge.plan(source: source, target: plist.mergeTarget())
            var created: [String] = []
            for insertion in plan.insertions { created += try plist.insert(insertion.nodes, into: insertion.parentRef) }

            let reread = try SafariBookmarksPlist(data: try plist.data())
            let bar = reread.syncSource().children(.bar)
            expectEqual(bar.map(\.title), ["Apple", "工具", "Example", "Folder"])
            expectEqual(reread.syncSource().children(.other).map(\.title), ["读书", "Other one"])
            let raw = try PropertyListSerialization.propertyList(from: try plist.data(), format: nil) as! [String: Any]
            let favorites = (raw["Children"] as! [[String: Any]]).first { $0["Title"] as? String == "BookmarksBar" }!
            let apple = (favorites["Children"] as! [[String: Any]])[0]
            expectNotNil(apple["Sync"], "existing iCloud metadata is untouched")
            expectTrue(BookmarkMerge.plan(source: source, target: reread.mergeTarget()).isEmpty, "second run adds nothing")

            expectEqual(reread.linkCount(uuids: Set(created)), 3)
            expectEqual(reread.remove(uuids: Set(created)), created.count)
            expectEqual(reread.syncSource().linkCount, try SafariBookmarksPlist(data: try fixture()).syncSource().linkCount)
        },

        TestCase("rejects files that are not Safari bookmarks") {
            let other = try PropertyListSerialization.data(fromPropertyList: ["Foo": 1], format: .binary, options: 0)
            expectThrows { _ = try SafariBookmarksPlist(data: other) }
        },
    ]
}
