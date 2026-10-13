import Foundation

/// Reader/writer for the Netscape bookmark file format (`bookmarks.html`).
///
/// This is the universal interchange format: Safari, Chrome, Edge, Brave, Opera,
/// Firefox, Vivaldi and every other mainstream browser can both import and export it.
public enum NetscapeHTML {

    // MARK: - Writing

    public static func write(_ tree: BookmarkTree) -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <!-- This is an automatically generated file.
             It will be read and overwritten.
             DO NOT EDIT! -->
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        for root in tree.roots {
            out += render(root.node, indent: 1, isToolbar: root.id == "bookmark_bar")
        }
        out += "</DL><p>\n"
        return out
    }

    private static func render(_ node: BookmarkNode, indent: Int, isToolbar: Bool = false) -> String {
        let pad = String(repeating: "    ", count: indent)
        switch node.kind {
        case .link:
            var line = "\(pad)<DT><A HREF=\"\(escapeAttribute(node.href))\""
            if let d = plausible(node.dateAdded) { line += " ADD_DATE=\"\(Int(d.timeIntervalSince1970))\"" }
            line += ">\(escapeText(node.title))</A>\n"
            if let note = node.annotation, !note.isEmpty {
                line += "\(pad)<DD>\(escapeText(note))\n"
            }
            return line
        case .folder:
            var line = "\(pad)<DT><H3"
            if let d = plausible(node.dateAdded) { line += " ADD_DATE=\"\(Int(d.timeIntervalSince1970))\"" }
            if isToolbar { line += " PERSONAL_TOOLBAR_FOLDER=\"true\"" }
            line += ">\(escapeText(node.title))</H3>\n"
            if let note = node.annotation, !note.isEmpty {
                line += "\(pad)<DD>\(escapeText(note))\n"
            }
            line += "\(pad)<DL><p>\n"
            for child in node.children {
                line += render(child, indent: indent + 1)
            }
            line += "\(pad)</DL><p>\n"
            return line
        }
    }

    /// Timestamps at or below the Unix epoch are placeholders, not real dates; emitting them
    /// would turn into `ADD_DATE="0"` and confuse the importing browser.
    static func plausible(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 946_684_800 else { return nil }   // 2000-01-01
        return date
    }

    static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Tokenizer

    enum Token: Equatable {
        case tag(name: String, attributes: [String: String])
        case text(String)
    }

    static func tokenize(_ html: String) -> [Token] {
        var tokens: [Token] = []
        var i = html.startIndex
        let end = html.endIndex
        while i < end {
            guard let lt = html[i...].firstIndex(of: "<") else {
                tokens.append(.text(String(html[i...])))
                break
            }
            if lt > i { tokens.append(.text(String(html[i..<lt]))) }
            if html[lt...].hasPrefix("<!--") {
                guard let closeRange = html[lt...].range(of: "-->") else { break }
                i = closeRange.upperBound
                continue
            }
            guard let gt = html[lt...].firstIndex(of: ">") else {
                tokens.append(.text(String(html[lt...])))
                break
            }
            let body = String(html[html.index(after: lt)..<gt])
            if let token = parseTag(body) { tokens.append(token) }
            i = html.index(after: gt)
        }
        return tokens
    }

    private static func parseTag(_ body: String) -> Token? {
        var s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("!") || s.hasPrefix("?") { return nil }  // doctype / PI
        var closing = false
        if s.hasPrefix("/") { closing = true; s = String(s.dropFirst()) }
        var name = ""
        var rest = Substring(s)
        for ch in s {
            if ch.isLetter || ch.isNumber { name.append(ch); rest = rest.dropFirst() } else { break }
        }
        guard !name.isEmpty else { return nil }
        if closing { return .tag(name: "/" + name.lowercased(), attributes: [:]) }
        // Trim a trailing self-closing slash.
        var attrText = String(rest)
        if attrText.hasSuffix("/") { attrText = String(attrText.dropLast()) }
        return .tag(name: name.lowercased(), attributes: parseAttributes(attrText))
    }

    public static func parseAttributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex && !(s[i].isLetter || s[i] == "_") { i = s.index(after: i) }
            var name = ""
            while i < s.endIndex && (s[i].isLetter || s[i].isNumber || s[i] == "_" || s[i] == "-") {
                name.append(s[i]); i = s.index(after: i)
            }
            guard !name.isEmpty else { break }
            while i < s.endIndex && s[i].isWhitespace { i = s.index(after: i) }
            if i < s.endIndex && s[i] == "=" {
                i = s.index(after: i)
                while i < s.endIndex && s[i].isWhitespace { i = s.index(after: i) }
                var value = ""
                if i < s.endIndex && (s[i] == "\"" || s[i] == "'") {
                    let quote = s[i]
                    i = s.index(after: i)
                    while i < s.endIndex && s[i] != quote { value.append(s[i]); i = s.index(after: i) }
                    if i < s.endIndex { i = s.index(after: i) }
                } else {
                    while i < s.endIndex && !s[i].isWhitespace { value.append(s[i]); i = s.index(after: i) }
                }
                let key = name.lowercased()
                if out[key] == nil { out[key] = value }
            } else {
                let key = name.lowercased()
                if out[key] == nil { out[key] = "" }
            }
        }
        return out
    }

    // MARK: - Reading

    public enum ParseError: Error, CustomStringConvertible {
        case notNetscapeBookmarks
        public var description: String {
            switch self {
            case .notNetscapeBookmarks: return "file does not look like a Netscape bookmark export"
            }
        }
    }

    /// Internal mutable tree used while parsing.
    final class Builder {
        var kind: BookmarkNode.Kind
        var title: String
        var url: String?
        var dateAdded: Date?
        var annotation: String?
        var children: [Builder] = []
        init(kind: BookmarkNode.Kind, title: String = "", url: String? = nil, dateAdded: Date? = nil, annotation: String? = nil) {
            self.kind = kind
            self.title = title
            self.url = url
            self.dateAdded = dateAdded
            self.annotation = annotation
        }
        func freeze() -> BookmarkNode {
            BookmarkNode(
                kind: kind,
                title: title,
                url: url,
                dateAdded: dateAdded,
                annotation: annotation,
                children: children.map { $0.freeze() }
            )
        }
    }

    enum Capture: Equatable {
        case none
        case folder(attributes: [String: String])
        case link(attributes: [String: String])
        case description

        static func == (lhs: Capture, rhs: Capture) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.description, .description): return true
            case (.folder(let a), .folder(let b)): return a == b
            case (.link(let a), .link(let b)): return a == b
            default: return false
            }
        }

        var isNone: Bool { if case .none = self { return true }; return false }
    }

    public static func parse(_ html: String) throws -> BookmarkTree {
        let lowered = html.lowercased()
        guard lowered.contains("<dl") else { throw ParseError.notNetscapeBookmarks }

        let tokens = tokenize(html)
        let implicitRoot = Builder(kind: .folder, title: "Bookmarks")
        var stack: [Builder] = [implicitRoot]
        // `dlDepth` counts opened <DL> elements. The outermost one is the document's.
        var dlDepth = 0
        var pendingFolder: Builder?
        var capture: Capture = .none
        var buffer = ""
        /// Root-level named folders, in encounter order, with their DL nesting marked.
        var topLevelFolders: [(builder: Builder, isToolbar: Bool)] = []

        func current() -> Builder { stack[stack.count - 1] }

        func finishCapture() {
            switch capture {
            case .none:
                break
            case .folder(let attrs):
                let title = decodeEntities(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                let node = Builder(
                    kind: .folder,
                    title: title,
                    dateAdded: date(fromEpochAttribute: attrs["add_date"]),
                    annotation: attrs["description"].map(decodeEntities)
                )
                current().children.append(node)
                pendingFolder = node
                if dlDepth <= 1 {
                    let toolbar = attrs["personal_toolbar_folder"]?.lowercased() == "true"
                    topLevelFolders.append((node, toolbar))
                }
            case .link(let attrs):
                let title = decodeEntities(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = decodeEntities(attrs["href"] ?? "")
                let node = Builder(
                    kind: .link,
                    title: title.isEmpty ? url : title,
                    url: url,
                    dateAdded: date(fromEpochAttribute: attrs["add_date"]),
                    annotation: attrs["description"].map(decodeEntities)
                )
                current().children.append(node)
                pendingFolder = nil
            case .description:
                let text = decodeEntities(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, let last = current().children.last {
                    last.annotation = text
                }
            }
            capture = .none
            buffer = ""
        }

        for token in tokens {
            switch token {
            case .text(let t):
                switch capture {
                case .none: break
                default: buffer += t
                }
            case .tag(let name, let attributes):
                switch name {
                case "dl":
                    // A <DL> binds to the folder declared immediately before it.
                    if let folder = pendingFolder, capture.isNone {
                        stack.append(folder)
                        pendingFolder = nil
                    } else {
                        stack.append(Builder(kind: .folder, title: ""))
                    }
                    dlDepth += 1
                    finishCapture()
                case "/dl":
                    finishCapture()
                    if dlDepth > 0 { dlDepth -= 1 }
                    if stack.count > 1 { stack.removeLast() }
                    pendingFolder = nil
                case "dt":
                    finishCapture()
                case "h3":
                    finishCapture()
                    capture = .folder(attributes: attributes)
                    buffer = ""
                case "/h3", "/a", "/dd":
                    finishCapture()
                case "a":
                    finishCapture()
                    capture = .link(attributes: attributes)
                    buffer = ""
                case "dd":
                    finishCapture()
                    capture = .description
                    buffer = ""
                case "p", "br", "meta", "/p", "/dt", "/h1", "/title", "h1", "title", "/dl":
                    finishCapture()
                default:
                    break
                }
            }
        }
        finishCapture()

        // Assemble the roots. Top-level folders become roots; anything left directly on
        // the implicit root becomes an "other" root.
        var roots: [BookmarkTree.RootFolder] = []
        var barIndex: Int?
        for entry in topLevelFolders {
            let toolbar = entry.isToolbar || isToolbarTitle(entry.builder.title)
            let id = toolbar ? "bookmark_bar" : (roots.contains(where: { $0.id == "other" }) ? "other" : sanitizeID(entry.builder.title))
            if toolbar, barIndex == nil { barIndex = roots.count }
            if toolbar, let idx = roots.firstIndex(where: { $0.id == "bookmark_bar" }) {
                // Duplicate toolbar folders: merge children.
                roots[idx].node.children.append(contentsOf: entry.builder.children.map { $0.freeze() })
                continue
            }
            roots.append(.init(id: id, title: entry.builder.title, node: entry.builder.freeze()))
        }
        if roots.isEmpty {
            let node = implicitRoot.freeze()
            if !node.children.isEmpty { roots = [.init(id: "other", title: "Bookmarks", node: node)] }
        }
        return BookmarkTree(source: "netscape", roots: roots)
    }

    private static func isToolbarTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        return t == "bookmarks bar" || t == "bookmarks toolbar" || t == "favorites bar"
            || t == "收藏夹栏" || t == "书签栏" || t == "个人收藏夹" || t == "personal toolbar"
    }

    private static func sanitizeID(_ title: String) -> String {
        let allowed = title.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let s = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "other" : s
    }

    private static func date(fromEpochAttribute value: String?) -> Date? {
        guard let value, let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds > 0 else { return nil }
        // Some producers emit microseconds or milliseconds.
        if seconds > 1_000_000_000_000 { return Date(timeIntervalSince1970: seconds / 1_000_000) }
        if seconds > 100_000_000_000 { return Date(timeIntervalSince1970: seconds / 1_000) }
        return Date(timeIntervalSince1970: seconds)
    }

    private static let namedEntities: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "hellip": "\u{2026}", "mdash": "\u{2014}",
        "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}",
        "rdquo": "\u{201D}", "middot": "\u{00B7}", "times": "\u{00D7}", "laquo": "\u{00AB}",
        "raquo": "\u{00BB}", "deg": "\u{00B0}", "trade": "\u{2122}", "euro": "\u{20AC}",
        "pound": "\u{00A3}", "yen": "\u{00A5}", "sect": "\u{00A7}", "bull": "\u{2022}",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "&", let semi = s[i...].firstIndex(of: ";"),
                  s.distance(from: i, to: semi) <= 12 else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            let body = String(s[s.index(after: i)..<semi])
            if body.hasPrefix("#") {
                let numPart = body.dropFirst()
                let scalarValue: UInt32? = (numPart.hasPrefix("x") || numPart.hasPrefix("X"))
                    ? UInt32(numPart.dropFirst(), radix: 16)
                    : UInt32(numPart)
                if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                    out.append(Character(scalar))
                    i = s.index(after: semi)
                    continue
                }
            } else if let ch = namedEntities[body.lowercased()] {
                out.append(ch)
                i = s.index(after: semi)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
