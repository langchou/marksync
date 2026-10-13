import Foundation
import MarkSyncCore

/// A trimmed-down but structurally faithful Chrome `Bookmarks` file.
let chromiumFixture = """
{
   "checksum": "abc",
   "roots": {
      "bookmark_bar": {
         "children": [
            { "date_added": "13300000000000000",
              "guid": "00000000-0000-0000-0000-000000000001",
              "id": "5",
              "name": "Example",
              "type": "url",
              "url": "https://example.com/" },
            { "children": [
                { "date_added": "13300000000000001",
                  "id": "7",
                  "name": "Nested",
                  "type": "url",
                  "url": "https://nested.example/" } ],
              "date_added": "13300000000000002",
              "id": "6",
              "name": "Folder",
              "type": "folder" }
         ],
         "date_added": "13300000000000003",
         "id": "1",
         "name": "Bookmarks bar",
         "type": "folder"
      },
      "other": {
         "children": [
            { "date_added": "13300000000000004",
              "id": "8",
              "meta_info": { "description": "with a note" },
              "name": "Other one",
              "type": "url",
              "url": "https://other.example/" }
         ],
         "id": "2",
         "name": "Other bookmarks",
         "type": "folder"
      },
      "synced": { "children": [], "id": "3", "name": "Mobile bookmarks", "type": "folder" }
   },
   "version": 1
}
"""

enum ChromiumBookmarksSuite {
    static let all: [TestCase] = [
        TestCase("parse Chromium JSON") {
            let tree = try ChromiumBookmarks.parse(Data(chromiumFixture.utf8))
            expectEqual(tree.source, "chromium")
            expectEqual(tree.linkCount, 3)
            let bar = try unwrap(tree.roots.first { $0.id == "bookmark_bar" })
            expectEqual(bar.node.children.count, 2)
            expectEqual(bar.node.children[0].title, "Example")
            expectEqual(bar.node.children[0].url, "https://example.com/")
            expectEqual(bar.node.children[1].children.first?.url, "https://nested.example/")
            let other = try unwrap(tree.roots.first { $0.id == "other" })
            expectEqual(other.node.children.first?.annotation, "with a note")
        },

        TestCase("Chromium timestamp conversion") {
            // 13300000000000000 µs since 1601-01-01T00:00:00Z → 2022-06-18T04:26:40Z
            let date = try unwrap(ChromiumBookmarks.date(fromChromium: "13300000000000000"))
            expectEqual(date.timeIntervalSince1970, 1_655_526_400, accuracy: 1)
            expectEqual(ChromiumBookmarks.chromiumValue(from: date), "13300000000000000")
        },

        TestCase("write then parse round trip") {
            let tree = try ChromiumBookmarks.parse(Data(chromiumFixture.utf8))
            let data = try ChromiumBookmarks.write(tree)
            let reparsed = try ChromiumBookmarks.parse(data)
            expectEqual(reparsed.linkCount, tree.linkCount)
            expectEqual(reparsed.folderCount, tree.folderCount)
            func urls(_ t: BookmarkTree) -> Set<String> {
                var out: Set<String> = []
                t.rootNode.walk { n, _ in if let u = n.url { out.insert(u) } }
                return out
            }
            expectEqual(urls(reparsed), urls(tree))
        },

        TestCase("rejects malformed input") {
            expectThrows { _ = try ChromiumBookmarks.parse(Data("{\"version\":1}".utf8)) }
            expectThrows { _ = try ChromiumBookmarks.parse(Data("not json".utf8)) }
        },

        TestCase("tolerates numeric and missing date_added") {
            let json = """
            {"roots":{"other":{"children":[
              {"type":"url","name":"A","url":"https://a/","date_added":13300000000000000},
              {"type":"url","name":"B","url":"https://b/"}
            ],"type":"folder","name":"Other"}}}
            """
            let tree = try ChromiumBookmarks.parse(Data(json.utf8))
            expectEqual(tree.linkCount, 2)
            expectNotNil(tree.roots.first?.node.children.first?.dateAdded)
            expectNil(tree.roots.first?.node.children.last?.dateAdded)
        },
    ]
}

/// Firefox keeps bookmarks in `places.sqlite`; the fixture below mirrors `moz_bookmarks`
/// (type 2 = folder, 1 = bookmark) joined against `moz_places`.
enum FirefoxSuite {
    static func makePlaces() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marksync-ff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("places.sqlite").path
        let sql = """
        create table moz_places (id integer primary key, url text);
        create table moz_bookmarks (id integer primary key, type integer, fk integer, parent integer, title text, dateAdded integer);
        insert into moz_places (id,url) values (10,'https://ff.example/a'),(11,'https://ff.example/b');
        insert into moz_bookmarks (id,type,parent,title,dateAdded) values
          (1,2,0,'root',0),(2,2,1,'menu',0),(3,2,1,'toolbar',0),(4,2,1,'unfiled',0),(5,2,1,'mobile',0);
        insert into moz_bookmarks (id,type,fk,parent,title,dateAdded) values
          (20,1,10,3,'FF A',1700000000000000),
          (21,2,NULL,3,'FF Folder',1700000000000001),
          (22,1,11,21,'FF B',1700000000000002),
          (23,1,11,4,'FF Unfiled',1700000000000003);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { skip("sqlite3 CLI unavailable") }
        return path
    }

    static let all: [TestCase] = [
        TestCase("parses places.sqlite into a tree") {
            let path = try makePlaces()
            let tree = try FirefoxBookmarks.parse(path: path)
            expectEqual(tree.source, "firefox")
            expectEqual(tree.linkCount, 3)
            let bar = try unwrap(tree.roots.first { $0.id == "bookmark_bar" })
            expectEqual(bar.node.children.count, 2)
            expectEqual(bar.node.children[0].title, "FF A")
            expectEqual(bar.node.children[0].url, "https://ff.example/a")
            expectEqual(bar.node.children[1].title, "FF Folder")
            expectEqual(bar.node.children[1].children.first?.url, "https://ff.example/b")
            let other = try unwrap(tree.roots.first { $0.id == "other" })
            expectEqual(other.node.children.first?.title, "FF Unfiled")
            // dateAdded is microseconds since the Unix epoch.
            expectEqual(bar.node.children[0].dateAdded?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 1)
        },

        TestCase("auto-detects places.sqlite") {
            let path = try makePlaces()
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            expectEqual(BookmarkFormat.detect(data, path: path), .firefoxSQLite)
            let tree = try BookmarkFile.read(path: path, explicitFormat: nil)
            expectEqual(tree.linkCount, 3)
        },
    ]
}

enum FormatDetectionSuite {
    static let all: [TestCase] = [
        TestCase("detects Netscape HTML by content and extension") {
            let html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p><DT><A HREF=\"x\">y</A>"
            expectEqual(BookmarkFormat.detect(Data(html.utf8), path: "bookmarks.html"), .netscapeHTML)
            expectEqual(BookmarkFormat.detect(Data(html.utf8), path: "export"), .netscapeHTML)
        },

        TestCase("detects Chromium JSON") {
            let json = #"{"checksum":"","roots":{"bookmark_bar":{"children":[]}},"version":1}"#
            expectEqual(BookmarkFormat.detect(Data(json.utf8), path: "Bookmarks"), .chromiumJSON)
        },

        TestCase("detects this tool's own JSON tree") {
            let json = #"{"source":"safari","roots":[{"id":"a","title":"A","children":[]}]}"#
            expectEqual(BookmarkFormat.detect(Data(json.utf8), path: "tree.json"), .treeJSON)
        },

        TestCase("returns nil for unsupported files") {
            expectNil(BookmarkFormat.detect(Data("bplist00\u{01}\u{02}".utf8), path: "Bookmarks.plist"))
        },
    ]
}

/// The browser locator must find profile directories it was never told about, and must pick
/// exactly one bookmark file per profile (`Bookmarks` when it holds something, otherwise
/// `AccountBookmarks`).
enum BrowserLocatorSuite {
    static func makeFakeHome() throws -> String {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marksync-home-\(UUID().uuidString)")
        let base = home.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        func write(_ path: String, _ contents: String) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        func chromium(_ names: [String]) -> String {
            let kids = names.map { #"{"type":"url","name":"\#($0)","url":"https://\#($0).example/"}"# }.joined(separator: ",")
            return #"{"roots":{"bookmark_bar":{"type":"folder","name":"bar","children":[\#(kids)]}},"version":1}"#
        }
        // A profile with a populated local file, one with only an account file, one with an
        // empty local file plus a populated account file, and a non-profile directory.
        try write("Google/Chrome/Default/Bookmarks", chromium(["local"]))
        try write("Google/Chrome/Profile 11/AccountBookmarks", chromium(["acct1", "acct2"]))
        try write("Google/Chrome/Profile 3/Bookmarks", #"{"roots":{"bookmark_bar":{"type":"folder","name":"bar","children":[]}}}"#)
        try write("Google/Chrome/Profile 3/AccountBookmarks", chromium(["fallback"]))
        try write("Google/Chrome/System Profile/Bookmarks", chromium(["nope"]))
        try write("Microsoft Edge/Default/Bookmarks", chromium(["edge1"]))
        return home.path
    }

    static let all: [TestCase] = [
        TestCase("finds unknown profile directories and AccountBookmarks") {
            let home = try makeFakeHome()
            let files = try BrowserLocator.bookmarkFiles(forBrowser: "chrome", home: home)
            let labels = files.map(\.label).sorted()
            expectEqual(labels, ["chrome Default", "chrome Profile 11 (account)", "chrome Profile 3 (account)"])
            let byLabel = Dictionary(uniqueKeysWithValues: files.map { ($0.label, $0.path) })
            expectTrue(byLabel["chrome Profile 11 (account)"]?.hasSuffix("AccountBookmarks") ?? false)
            // Profile 3 has an *empty* local file and a populated account file: the account file
            // must win, otherwise the bookmarks would be silently invisible.
            expectTrue(byLabel["chrome Profile 3 (account)"]?.hasSuffix("AccountBookmarks") ?? false)
            expectEqual(byLabel["chrome Default"]?.hasSuffix("/Default/Bookmarks"), true, "a populated local file wins")
        },

        TestCase("counts links per file") {
            let home = try makeFakeHome()
            let files = try BrowserLocator.bookmarkFiles(forBrowser: "chrome", home: home)
            let counts = files.map { BrowserLocator.chromiumLinkCount(path: $0.path) ?? -1 }
            expectEqual(counts.reduce(0, +), 4, "1 local + 2 account + 1 fallback")
        },

        TestCase("other browsers are unaffected") {
            let home = try makeFakeHome()
            expectEqual(try BrowserLocator.bookmarkFiles(forBrowser: "edge", home: home).count, 1)
            expectEqual(try BrowserLocator.bookmarkFiles(forBrowser: "all", home: home).count, 4)
            expectThrows { _ = try BrowserLocator.bookmarkFiles(forBrowser: "netscape", home: home) }
        },
    ]
}
