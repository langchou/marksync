import Foundation
import MarkSyncCore

enum NetscapeHTMLSuite {
    static func sampleTree() -> BookmarkTree {
        let bar = BookmarkNode.folder("Bookmarks Bar", children: [
            .link("Example", "https://example.com/", dateAdded: Date(timeIntervalSince1970: 1_700_000_000)),
            .folder("Tools", children: [
                .link("Quoted \"name\" & <tags>", "https://example.com/a?b=1&c=2", annotation: "A note"),
            ]),
        ])
        let other = BookmarkNode.folder("Other", children: [
            .link("中文标题", "https://例子.测试/路径"),
        ])
        return BookmarkTree(source: "test", roots: [
            .init(id: "bookmark_bar", title: "Bookmarks Bar", node: bar),
            .init(id: "other", title: "Other", node: other),
        ])
    }

    static let all: [TestCase] = [
        TestCase("write then parse round trip") {
            let original = sampleTree()
            let html = NetscapeHTML.write(original)
            expectTrue(html.contains("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
            expectTrue(html.contains("PERSONAL_TOOLBAR_FOLDER=\"true\""))

            let parsed = try NetscapeHTML.parse(html)
            expectEqual(parsed.roots.count, 2)
            expectEqual(parsed.linkCount, original.linkCount)
            expectEqual(parsed.folderCount, original.folderCount)

            let bar = try unwrap(parsed.roots.first { $0.id == "bookmark_bar" })
            expectEqual(bar.node.children.count, 2)
            expectEqual(bar.node.children[0].title, "Example")
            expectEqual(bar.node.children[0].url, "https://example.com/")
            expectEqual(bar.node.children[0].dateAdded, Date(timeIntervalSince1970: 1_700_000_000))

            let tools = try unwrap(bar.node.children[1].children.first)
            expectEqual(tools.title, "Quoted \"name\" & <tags>")
            expectEqual(tools.url, "https://example.com/a?b=1&c=2")
            expectEqual(tools.annotation, "A note")
        },

        TestCase("parse a real Chrome/Edge export") {
            // Shape produced by "Export bookmarks": unclosed <DT> tags, a nested <DL> after
            // <H3>, and a <DD> description.
            let html = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <!-- This is an automatically generated file. -->
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>
            <DL><p>
                <DT><H3 ADD_DATE="1690000000" LAST_MODIFIED="1690000001" PERSONAL_TOOLBAR_FOLDER="true">收藏夹栏</H3>
                <DL><p>
                    <DT><A HREF="https://a.example/" ADD_DATE="1690000002">A &amp; B</A>
                    <DT><A HREF="https://b.example/" ADD_DATE="1690000003">B</A>
                    <DD>desc for B
                    <DT><H3 ADD_DATE="1690000004">子目录</H3>
                    <DL><p>
                        <DT><A HREF="https://c.example/?x=1&amp;y=2">C</A>
                    </DL><p>
                </DL><p>
                <DT><H3 ADD_DATE="1690000005">其他收藏夹</H3>
                <DL><p>
                    <DT><A HREF="https://d.example/">D</A>
                </DL><p>
            </DL><p>
            """
            let tree = try NetscapeHTML.parse(html)
            expectEqual(tree.linkCount, 4)
            let bar = try unwrap(tree.roots.first { $0.id == "bookmark_bar" })
            expectEqual(bar.title, "收藏夹栏")
            expectEqual(bar.node.children.count, 3)
            expectEqual(bar.node.children[0].title, "A & B")
            expectEqual(bar.node.children[1].annotation, "desc for B")
            expectEqual(bar.node.children[2].title, "子目录")
            expectEqual(bar.node.children[2].children.first?.url, "https://c.example/?x=1&y=2")

            let other = try unwrap(tree.roots.first { $0.id != "bookmark_bar" })
            expectEqual(other.node.children.first?.title, "D")
        },

        TestCase("rejects HTML that is not a bookmark file") {
            expectThrows { _ = try NetscapeHTML.parse("<html><body>hello</body></html>") }
        },

        TestCase("entity decoding") {
            expectEqual(NetscapeHTML.decodeEntities("a&amp;b"), "a&b")
            expectEqual(NetscapeHTML.decodeEntities("&#65;&#x42;"), "AB")
            expectEqual(NetscapeHTML.decodeEntities("&lt;tag&gt;"), "<tag>")
            expectEqual(NetscapeHTML.decodeEntities("中文&amp;测试"), "中文&测试")
            expectEqual(NetscapeHTML.decodeEntities("a & b"), "a & b")
            expectEqual(NetscapeHTML.decodeEntities("&nosuch;"), "&nosuch;")
        },

        TestCase("attribute parsing") {
            let attrs = NetscapeHTML.parseAttributes(" ADD_DATE=\"1690000000\" PERSONAL_TOOLBAR_FOLDER=\"true\" href=https://x/ ")
            expectEqual(attrs["add_date"], "1690000000")
            expectEqual(attrs["personal_toolbar_folder"], "true")
            expectEqual(attrs["href"], "https://x/")
        },

        TestCase("escaping round trip with hostile characters") {
            let nasty = BookmarkNode.link("a<b>c&d\"e", "https://x/?q=\"&<>")
            let tree = BookmarkTree(source: "t", roots: [.init(id: "other", title: "O", node: .folder("O", children: [nasty]))])
            let parsed = try NetscapeHTML.parse(NetscapeHTML.write(tree))
            expectEqual(parsed.roots.first?.node.children.first?.title, "a<b>c&d\"e")
            expectEqual(parsed.roots.first?.node.children.first?.url, "https://x/?q=\"&<>")
        },

        TestCase("handles a folder with no children and an empty file body") {
            let tree = BookmarkTree(source: "t", roots: [.init(id: "other", title: "O", node: .folder("O", children: []))])
            let parsed = try NetscapeHTML.parse(NetscapeHTML.write(tree))
            expectEqual(parsed.roots.count, 1)
            expectEqual(parsed.linkCount, 0)
        },
    ]
}
