"""Read-only look at where Safari keeps Favorites, for debugging `marksync sync --to safari`.

Usage: python3 -I scripts/diagnose-safari.py [created ids ...]

Opens SafariTabs.db read-only and prints folder structure and counts. Prints folder titles
but not your bookmark URLs. Needs Full Disk Access for the terminal running it.
"""
import os
import plistlib
import sqlite3
import sys

home = os.path.expanduser("~")
db = f"{home}/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db"
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
cols = [r[1] for r in con.execute("pragma table_info(bookmarks)")]
print("bookmarks columns:", ", ".join(cols))


def attrs(blob):
    if not blob:
        return {}
    try:
        return plistlib.loads(blob)
    except Exception as e:
        return {"<undecodable>": type(e).__name__}


def describe(value, depth=0):
    """Keys and short scalar values only — no URLs, no long blobs."""
    if isinstance(value, dict):
        return "{" + ", ".join(f"{k}: {describe(v, depth + 1)}" for k, v in value.items()) + "}"
    if isinstance(value, (bytes, bytearray)):
        return f"<{len(value)} bytes>"
    if isinstance(value, list):
        return f"[{len(value)} items]"
    text = str(value)
    return text if len(text) <= 60 else text[:57] + "..."


def kids(pid):
    return con.execute(
        "select id, type, title, hidden, deleted, subtype from bookmarks where parent = ? order by order_index", (pid,)
    ).fetchall()


def count_links(pid):
    n = 0
    for cid, typ, _, _, deleted, _ in kids(pid):
        if deleted:
            continue
        n += count_links(cid) if typ == 1 else 1
    return n


extra = [c for c in ("external_uuid", "server_id", "special_id", "num_children") if c in cols]
sel = ", ".join(["id", "parent", "type", "title", "hidden", "deleted", "subtype"] + extra + ["extra_attributes"])

print("\n== root-level folders (parent is null or 0)")
for row in con.execute(f"select {sel} from bookmarks where (parent is null or parent = 0) and type = 1 order by id"):
    rid, parent, typ, title, hidden, deleted, subtype, *rest = row
    blob = rest[-1]
    info = dict(zip(extra, rest[:-1]))
    print(f"#{rid:<5} parent={parent!s:<5} hidden={hidden} deleted={deleted} subtype={subtype} "
          f"links={count_links(rid):<4} title={title!r} {info}")
    a = attrs(blob)
    if a:
        print("        extra_attributes:", describe(a))

print("\n== every folder titled like Favorites / BookmarksBar")
for row in con.execute("select id, parent, title, hidden, deleted from bookmarks where type = 1 and "
                       "(title like '%Bookmark%Bar%' or title like '%Favorite%' or title like '%收藏%')"):
    print(f"#{row[0]} parent={row[1]} hidden={row[3]} deleted={row[4]} title={row[2]!r} links={count_links(row[0])}")

ids = [int(x) for x in sys.argv[1:]]
if ids:
    print("\n== rows created by the sync")
    for i in ids:
        r = con.execute("select id, parent, type, title, hidden, deleted from bookmarks where id = ?", (i,)).fetchone()
        if not r:
            print(f"#{i}: not in the database")
            continue
        chain, p = [], r[1]
        while p is not None:
            pr = con.execute("select id, parent, title from bookmarks where id = ?", (p,)).fetchone()
            if not pr:
                break
            chain.append(f"#{pr[0]} {pr[2]!r}")
            p = pr[1] if pr[1] != pr[0] else None
        kind = "folder" if r[2] == 1 else "link"
        print(f"#{r[0]} {kind} title={r[3]!r} hidden={r[4]} deleted={r[5]}  under: {' <- '.join(chain)}")

print("\n== Safari preferences mentioning favorites/profiles")
for prefs in (f"{home}/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist",
              f"{home}/Library/Preferences/com.apple.Safari.plist"):
    try:
        p = plistlib.load(open(prefs, "rb"))
    except Exception as e:
        print(f"{prefs}: {type(e).__name__}")
        continue
    for k, v in sorted(p.items()):
        if any(w in k.lower() for w in ("favorite", "profile", "bookmarksbar", "bookmarks bar")):
            print(f"  {k} = {describe(v)}")

print("\n== legacy Bookmarks.plist")
plist = f"{home}/Library/Safari/Bookmarks.plist"
try:
    root = plistlib.load(open(plist, "rb"))

    def walk(node, depth=0):
        children = node.get("Children", [])
        links = sum(1 for c in children if c.get("WebBookmarkType") == "WebBookmarkTypeLeaf")
        if depth <= 1:
            print("  " * depth + f"{node.get('Title', '(root)')!r}: {len(children)} children, {links} links")
        for c in children:
            if c.get("WebBookmarkType") == "WebBookmarkTypeList":
                walk(c, depth + 1)

    print(f"{os.path.getsize(plist)} bytes")
    walk(root)
except Exception as e:
    print(f"{plist}: {type(e).__name__}: {e}")
