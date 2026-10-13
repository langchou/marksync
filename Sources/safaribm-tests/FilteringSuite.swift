import Foundation
import SafariBookmarksCore

private func sampleTree() -> BookmarkTree {
    let bar = BookmarkNode.folder("Bar", children: [
        .link("Alpha", "https://a.example/"),
        .folder("Dev", children: [
            .link("Beta", "https://b.example/"),
        ]),
    ])
    let other = BookmarkNode.folder("Other", children: [
        .link("Gamma", "https://c.example/"),
    ])
    return BookmarkTree(source: "t", roots: [
        .init(id: "bar", title: "Bar", node: bar),
        .init(id: "other", title: "Other", node: other),
    ])
}

enum FilteringSuite {
    static let all: [TestCase] = [
        TestCase("--only keeps the matching subtree") {
            let out = Filtering.apply(sampleTree(), only: "dev", exclude: nil, wrapTitle: nil, flatten: false)
            expectEqual(out.linkCount, 1)
            expectEqual(out.roots.count, 1)
            expectEqual(out.roots[0].node.children.first?.title, "Dev")
        },

        TestCase("--only matches URLs too") {
            let out = Filtering.apply(sampleTree(), only: "c.example", exclude: nil, wrapTitle: nil, flatten: false)
            expectEqual(out.linkCount, 1)
            expectEqual(out.roots[0].node.children.first?.title, "Gamma")
        },

        TestCase("--exclude empties the matching folder") {
            let out = Filtering.apply(sampleTree(), only: nil, exclude: "dev", wrapTitle: nil, flatten: false)
            expectEqual(out.linkCount, 2)
            let dev = out.roots[0].node.children.first { $0.title == "Dev" }
            expectEqual(dev?.children.count, 0)
        },

        TestCase("--flatten drops nesting") {
            let out = Filtering.apply(sampleTree(), only: nil, exclude: nil, wrapTitle: nil, flatten: true)
            expectEqual(out.roots.count, 1)
            expectEqual(out.roots[0].node.children.count, 3)
            expectTrue(out.roots[0].node.children.allSatisfy { $0.kind == .link })
        },

        TestCase("--title wraps the whole export") {
            let out = Filtering.apply(sampleTree(), only: nil, exclude: nil, wrapTitle: "Imported", flatten: false)
            expectEqual(out.roots.count, 1)
            expectEqual(out.roots[0].node.title, "Imported")
            expectEqual(out.roots[0].node.children.count, 2)
            expectEqual(out.linkCount, 3)
        },
    ]
}

enum DedupeSuite {
    static let all: [TestCase] = [
        TestCase("drops existing URLs and the folders they empty") {
            let node = BookmarkNode.folder("Root", children: [
                .link("Kept", "https://new.example/"),
                .link("Dropped", "https://old.example/"),
                .folder("EmptyAfter", children: [
                    .link("Dropped too", "https://old.example/"),
                ]),
            ])
            let pruned = try unwrap(Dedupe.prune(node, existing: ["https://old.example/"]))
            expectEqual(pruned.children.count, 1)
            expectEqual(pruned.children[0].title, "Kept")
        },
    ]
}

enum JSONTreeSuite {
    static let all: [TestCase] = [
        TestCase("JSON tree round trip") {
            let tree = BookmarkTree(source: "safari", roots: [
                .init(id: "bookmark_bar", title: "Bar", node: .folder("Bar", children: [
                    .link("X", "https://x.example/", dateAdded: Date(timeIntervalSince1970: 1_700_000_000), annotation: "note"),
                ])),
            ])
            let json = try JSONOutput.string(for: tree)
            let back = try JSONOutput.decodeTree(Data(json.utf8))
            expectEqual(back.source, "safari")
            expectEqual(back.linkCount, 1)
            let link = try unwrap(back.roots.first?.node.children.first)
            expectEqual(link.url, "https://x.example/")
            expectEqual(link.annotation, "note")
            expectEqual(link.dateAdded, Date(timeIntervalSince1970: 1_700_000_000))
        },
    ]
}

enum SerializeSuite {
    static let all: [TestCase] = [
        TestCase("every output format") {
            let tree = BookmarkTree(source: "t", roots: [
                .init(id: "other", title: "O", node: .folder("O", children: [.link("A", "https://a.example/")])),
            ])
            let html = try Serialize.data(tree, format: "html")
            expectTrue(String(data: html, encoding: .utf8)!.contains("NETSCAPE-Bookmark-file-1"))
            let chromium = try Serialize.data(tree, format: "chromium")
            expectEqual(try ChromiumBookmarks.parse(chromium).linkCount, 1)
            let json = try Serialize.data(tree, format: "json")
            expectEqual(try JSONOutput.decodeTree(json).linkCount, 1)
            expectThrows { _ = try Serialize.data(tree, format: "nope") }
        },

        TestCase("tree statistics") {
            let tree = BookmarkTree(source: "t", roots: [
                .init(id: "a", title: "A", node: .folder("A", children: [
                    .folder("B", children: [.link("C", "https://c/")]),
                    .link("D", "https://d/"),
                ])),
            ])
            expectEqual(tree.linkCount, 2)
            expectEqual(tree.folderCount, 2)
            expectEqual(tree.rootNode.maxDepth, 3)
        },
    ]
}
