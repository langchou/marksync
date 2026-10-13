import Foundation
import SafariBookmarksCore

/// Exercises the read path against a synthetic copy of Safari's `SafariTabs.db`.
///
/// The fixture reproduces the layout that trips up naive readers: profile folders have
/// `parent is null` (not `parent = 0`), they are hidden, and their identity lives in an
/// `extra_attributes` blob rather than in a column.
enum SafariModelSuite {

    static func blob(dateAdded: Date, omitFromUI: Bool) throws -> String {
        var attrs: [String: Any] = ["com.apple.Bookmark": ["DateAdded": dateAdded]]
        if omitFromUI { attrs["com.apple.bookmarks.OmitFromUI"] = true }
        let data = try PropertyListSerialization.data(fromPropertyList: attrs, format: .binary, options: 0)
        return data.map { String(format: "%02X", $0) }.joined()
    }

    /// Writes a `SafariTabs.db` shaped like macOS 26's and returns its path.
    static func makeDatabase() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("safaribm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("SafariTabs.db").path

        let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let privateDate = sharedDate.addingTimeInterval(0.000033)
        let barDate = Date(timeIntervalSince1970: 1_710_000_000)

        let statements = [
            """
            CREATE TABLE bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT, special_id INTEGER DEFAULT 0,
              parent INTEGER, type INTEGER, title TEXT, url TEXT, num_children INTEGER DEFAULT 0,
              editable INTEGER DEFAULT 1, deletable INTEGER DEFAULT 1, hidden INTEGER DEFAULT 0,
              hidden_ancestor_count INTEGER DEFAULT 0, order_index INTEGER NOT NULL,
              external_uuid TEXT, deleted INTEGER DEFAULT 0, subtype INTEGER DEFAULT 0,
              extra_attributes BLOB DEFAULT NULL, local_attributes BLOB DEFAULT NULL)
            """,
            "CREATE TABLE windows (id INTEGER PRIMARY KEY, local_tab_group_id INTEGER, private_tab_group_id INTEGER, uuid TEXT)",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,order_index,hidden,deleted) VALUES (0,NULL,0,1,'Root',0,0,0)",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,order_index,hidden,deleted,extra_attributes) VALUES (2,NULL,0,1,'pinned',0,1,0,X'\(try blob(dateAdded: barDate, omitFromUI: true))')",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,order_index,hidden,deleted,extra_attributes) VALUES (3,NULL,0,1,'Local',0,1,0,X'\(try blob(dateAdded: sharedDate, omitFromUI: true))')",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,order_index,hidden,deleted,extra_attributes) VALUES (4,NULL,0,1,'Private',0,1,0,X'\(try blob(dateAdded: privateDate, omitFromUI: true))')",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,order_index,hidden,deleted,extra_attributes) VALUES (5,NULL,6,1,'Recovered',0,1,0,NULL)",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,order_index,hidden,deleted,extra_attributes) VALUES (6,0,0,1,'BookmarksBar',0,0,0,X'\(try blob(dateAdded: barDate, omitFromUI: false))')",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,order_index,hidden,deleted,extra_attributes) VALUES (7,0,0,1,'com.apple.ReadingList',1,1,0,X'\(try blob(dateAdded: barDate, omitFromUI: true))')",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,url,order_index,hidden,deleted) VALUES (10,3,0,1,'Dev',NULL,0,0,0)",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,url,order_index,hidden,deleted,extra_attributes) VALUES (11,3,0,0,'Alpha','https://alpha.example/',0,0,0,X'\(try blob(dateAdded: sharedDate, omitFromUI: false))')",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,url,order_index,hidden,deleted,extra_attributes) VALUES (12,10,0,0,'Beta','https://beta.example/',0,0,0,X'\(try blob(dateAdded: sharedDate, omitFromUI: false))')",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,url,order_index,hidden,deleted) VALUES (13,3,0,0,'Gone','https://gone.example/',1,0,1)",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,url,order_index,hidden,deleted) VALUES (20,6,0,0,'BarLink','https://bar.example/',0,0,0)",
            "INSERT INTO bookmarks (id,parent,special_id,type,title,url,order_index,hidden,deleted) VALUES (21,7,0,0,'','https://read.example/',0,0,0)",
            "INSERT INTO windows (id,local_tab_group_id,private_tab_group_id,uuid) VALUES (1,3,4,'W')",
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data((statements.joined(separator: ";\n") + ";\n").utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            skip("sqlite3 CLI unavailable")
            throw TestFailure(message: "sqlite3 failed")
        }
        return path
    }

    static let all: [TestCase] = [
        TestCase("discovers profiles, special folders and legacy layout") {
            let model = try SafariModel(databasePath: try makeDatabase())
            expectEqual(model.bookmarksBar?.id, 6)
            expectEqual(model.readingListID, 7)
            expectEqual(model.recovered?.id, 5)
            expectNil(model.legacyContentFolder)

            expectEqual(model.profiles.count, 1)
            let profile = try unwrap(model.profiles.first)
            expectEqual(profile.localFolderID, 3)
            expectEqual(profile.privateFolderID, 4, "the Private sibling is paired by timestamp, not equality")
            expectEqual(profile.title, "Default", "the placeholder folder title is replaced by a display name")
            expectEqual(profile.linkCount, 2, "deleted rows must not be counted")
            expectEqual(profile.folderCount, 1)
        },

        TestCase("active profile comes from the windows table") {
            let model = try SafariModel(databasePath: try makeDatabase())
            expectEqual(model.activeProfileID(), 3)
            let destination = try unwrap(try model.destination(profileNamed: nil))
            expectEqual(destination.parentID, 3)
        },

        TestCase("tree excludes hidden and deleted rows by default") {
            let model = try SafariModel(databasePath: try makeDatabase())
            let tree = try model.tree()
            expectEqual(tree.roots.count, 3, "bar + profile + reading list")
            let bar = try unwrap(tree.roots.first { $0.id == "bookmark_bar" })
            expectEqual(bar.node.children.count, 1)
            expectEqual(bar.node.children.first?.url, "https://bar.example/")

            let profile = try unwrap(tree.roots.first { $0.id == "profile-3" })
            expectEqual(profile.node.children.count, 2)
            expectEqual(profile.node.children[0].title, "Dev")
            expectEqual(profile.node.children[0].children.first?.url, "https://beta.example/")

            let readingList = try unwrap(tree.roots.first { $0.id == "reading_list" })
            expectEqual(readingList.node.children.first?.title, "https://read.example/", "untitled reading list entries fall back to the URL")
        },

        TestCase("single profile tree") {
            let model = try SafariModel(databasePath: try makeDatabase())
            let withoutList = try model.tree(profile: "Default", includeReadingList: false)
            expectEqual(withoutList.roots.count, 1)
            expectEqual(withoutList.linkCount, 2)
            expectEqual(withoutList.roots[0].title, "Default")

            let withList = try model.tree(profile: "Default")
            expectEqual(withList.roots.count, 2, "the reading list is global, so it is exported too")
            expectEqual(withList.linkCount, 3)
        },

        TestCase("unknown profile is an error") {
            let model = try SafariModel(databasePath: try makeDatabase())
            expectThrows { _ = try model.tree(profile: "nope") }
            expectThrows { _ = try model.destination(profileNamed: "nope") }
        },

        TestCase("missing database is an error") {
            expectThrows { _ = try SafariModel(databasePath: "/nonexistent/SafariTabs.db") }
        },

        TestCase("existingURLs walks the whole subtree") {
            let model = try SafariModel(databasePath: try makeDatabase())
            expectEqual(model.existingURLs(under: 3), ["https://alpha.example/", "https://beta.example/"])
        },

        TestCase("extra-attribute blob decoding") {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["com.apple.Bookmark": ["DateAdded": Date(timeIntervalSince1970: 42)]],
                format: .binary, options: 0
            )
            let hex = data.map { String(format: "%02X", $0) }.joined()
            let date = try unwrap(SafariModel.dateAdded(fromExtraAttributesHex: hex))
            expectEqual(date.timeIntervalSince1970, 42, accuracy: 0.001)
            expectNil(SafariModel.dateAdded(fromExtraAttributesHex: "not-hex"))
            expectNil(SafariModel.dateAdded(fromExtraAttributesHex: nil))
            expectNil(SafariModel.annotation(fromExtraAttributesHex: hex))
        },

        TestCase("hex blob decoding edge cases") {
            expectEqual(Data(hexString: "00FF10"), Data([0x00, 0xFF, 0x10]))
            expectEqual(Data(hexString: "aaBB"), Data([0xAA, 0xBB]))
            expectNil(Data(hexString: "abc"))
            expectNil(Data(hexString: "zz"))
            expectEqual(Data(hexString: ""), Data())
        },
    ]
}

enum SQLiteSuite {
    static let all: [TestCase] = [
        TestCase("read-only queries on a missing file return nothing") {
            expectEqual(SQLite.rows(path: "/nonexistent/x.db", sql: "select 1"), [])
            expectEqual(SQLite.integers(path: "/nonexistent/x.db", sql: "select 1"), [])
        },

        TestCase("rows, integers and strings") {
            let path = try SafariModelSuite.makeDatabase()
            expectEqual(SQLite.integers(path: path, sql: "select count(*) from bookmarks"), [13])
            let titles = SQLite.strings(path: path, sql: "select title from bookmarks where id in (6,7) order by id")
            expectEqual(titles, ["BookmarksBar", "com.apple.ReadingList"])
            let row = try unwrap(SQLite.rows(path: path, sql: "select id, title from bookmarks where id = 11").first)
            expectEqual(row[0], "11")
            expectEqual(row[1], "Alpha")
        },
    ]
}
