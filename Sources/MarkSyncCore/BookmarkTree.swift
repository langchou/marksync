import Foundation

/// A browser-agnostic bookmark node. Folders have `children`, leaves have `url`.
public struct BookmarkNode: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case folder
        case link
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var url: String?
    /// Original browser date-added, when known.
    public var dateAdded: Date?
    /// Original browser-provided description/annotation, when known.
    public var annotation: String?
    public var children: [BookmarkNode]

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        url: String? = nil,
        dateAdded: Date? = nil,
        annotation: String? = nil,
        children: [BookmarkNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.dateAdded = dateAdded
        self.annotation = annotation
        self.children = children
    }

    public var isFolder: Bool { kind == .folder }

    public static func folder(_ title: String, children: [BookmarkNode] = []) -> BookmarkNode {
        BookmarkNode(kind: .folder, title: title, children: children)
    }

    public static func link(_ title: String, _ url: String, dateAdded: Date? = nil, annotation: String? = nil) -> BookmarkNode {
        BookmarkNode(kind: .link, title: title, url: url, dateAdded: dateAdded, annotation: annotation)
    }

    /// Depth-first walk over the whole subtree, self included.
    public func walk(_ body: (BookmarkNode, Int) -> Void, depth: Int = 0) {
        body(self, depth)
        for child in children { child.walk(body, depth: depth + 1) }
    }

    public var linkCount: Int {
        var n = 0
        walk { node, _ in if node.kind == .link { n += 1 } }
        return n
    }

    public var folderCount: Int {
        var n = 0
        walk { node, _ in if node.kind == .folder { n += 1 } }
        return n
    }

    public var maxDepth: Int {
        var d = 0
        walk { _, depth in d = max(d, depth) }
        return d
    }

    /// A syntactically valid href for the Netscape bookmark format.
    public var href: String {
        if let url, !url.isEmpty { return url }
        return "about:blank"
    }
}

/// A complete bookmark collection: a synthetic root plus named root folders.
public struct BookmarkTree: Sendable {
    public struct RootFolder: Sendable {
        /// Stable identity of the source root, e.g. `bookmark_bar`, `other`, `menu`, `mobile`.
        public var id: String
        public var title: String
        public var node: BookmarkNode
        public init(id: String, title: String, node: BookmarkNode) {
            self.id = id
            self.title = title
            self.node = node
        }
    }

    /// Where the tree came from: `safari`, `chrome`, `edge`, `brave`, `opera`, `chromium`,
    /// `firefox`, `netscape`.
    public var source: String
    public var roots: [RootFolder]

    public init(source: String, roots: [RootFolder]) {
        self.source = source
        self.roots = roots
    }

    public var rootNode: BookmarkNode {
        BookmarkNode(
            kind: .folder,
            title: "Bookmarks",
            children: roots.map(\.node)
        )
    }

    public var linkCount: Int { roots.reduce(0) { $0 + $1.node.linkCount } }
    public var folderCount: Int { roots.reduce(0) { $0 + $1.node.folderCount } }
}
