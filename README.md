# marksync

Sync bookmarks between **Safari** and **Chrome / Edge / Brave / Vivaldi / Opera** on macOS —
in whichever direction you choose, with the bookmarks bar landing on the bookmarks bar.

```
marksync sync --from edge   --to safari --dry-run     # preview
marksync sync --from edge   --to safari --yes         # Edge 收藏夹 → Safari
marksync sync --from safari --to chrome               # Safari → Chrome
marksync sync --undo last                             # revert the last sync
```

It also exports, imports and converts between bookmark formats:

```
marksync export --format html --out ~/Desktop/safari-bookmarks.html
marksync convert -s ~/edge-Bookmarks -t html -o ~/edge.html
```

No dependencies. Pure Swift and Foundation.

---

## Where each browser keeps its bookmarks

| browser | file |
|---|---|
| Safari | `~/Library/Safari/Bookmarks.plist` — Favorites, the sidebar and the reading list |
| Chrome, Edge, Brave, … | `~/Library/Application Support/<vendor>/<profile>/Bookmarks` (JSON); a signed-in profile may use `AccountBookmarks` instead |
| Firefox | `places.sqlite` in each profile (read only) |

Safari 17+ also has `~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db`,
whose `bookmarks` table holds **open tabs, tab groups and profiles**, not the bookmarks Safari
shows. An earlier version of this tool read and wrote that table; items written there never
appeared in Safari, and its "profile bookmarks" were open tabs. Verified on macOS 27 /
Safari 27: Safari's Favorites matched `Bookmarks.plist` › `BookmarksBar` exactly.

Reading or writing either file needs **Full Disk Access** for your terminal
(System Settings › Privacy & Security › Full Disk Access).

---

## Install

Requires macOS 14+ and the Xcode **Command Line Tools** (`xcode-select --install`).

```sh
git clone https://github.com/langchou/marksync.git && cd marksync
swift build -c release
sudo cp .build/release/marksync /usr/local/bin/       # optional
```

Run the test suite (56 tests, no XCTest needed):

```sh
swift run marksync-tests
```

---

## Commands

### `marksync sync`

Copies one browser's bookmarks into another. You choose the direction with `--from` and
`--to`; each run goes one way.

| option | meaning |
|---|---|
| `--from <browser>` / `--to <browser>` | `safari chrome edge brave chromium vivaldi opera`; `arc` and `firefox` only as `--from` |
| `--from-profile` / `--to-profile <name>` | Chromium: `Default`, `Profile 1` or the profile's display name. Without it: `Default`, or the only profile that has bookmarks |
| `--bar-only` | only the bookmarks bar / Favorites |
| `--dry-run` | print exactly what would be added |
| `--yes` | skip the confirmation prompt |
| `--undo <log\|last>` | revert a sync (each sync prints its log path) |

What goes where:

| Chrome / Edge | Safari |
|---|---|
| Bookmarks bar · 收藏夹栏 | Favorites · 个人收藏 |
| Other bookmarks · 其他收藏夹 | top level of the bookmarks sidebar |
| Mobile bookmarks · 移动收藏夹 | a folder of that name in the sidebar |

The sync is **additive**: it never deletes or moves anything in the target. Folders are
matched by name at the same place, and a bookmark is skipped when the same URL is already in
that part of the target (scheme and host compared case-insensitively, a bare trailing `/`
ignored). Running the same sync twice adds nothing the second time.

* **The target browser must be quit (⌘Q).** Browsers keep bookmarks in memory and rewrite the
  file on exit, so `sync` refuses to write while the target is running.
* **The file must not change underneath.** If something else (Safari's iCloud agent, the
  browser) writes the file between marksync reading and writing it, nothing is written.
* **Into Safari:** new items are appended to `Bookmarks.plist` with fresh `WebBookmarkUUID`s.
  Existing items, including their iCloud `Sync` metadata, are left byte-for-byte alone, so
  Safari treats the new ones as local additions and uploads them on its next iCloud sync.
* **Into Chrome/Edge/…:** only the local `Bookmarks` file is written (never
  `AccountBookmarks`); every existing field, including `sync_metadata`, is kept; new nodes get
  integer ids and GUIDs, and the checksum is recomputed.
* **Backups:** the previous file is kept next to it as `<file>.marksync-<time>.bak`.
* **Undo:** logs live in `~/Library/Application Support/marksync/undo/`. Undoing a Safari
  sync removes exactly the items it added (by UUID) and keeps everything else, including
  changes iCloud brought in since. Undoing a Chromium sync restores the backup, which also
  discards bookmark changes made in that browser after the sync.

`MARKSYNC_HOME=<dir>` points every lookup (Safari's plist, browser profiles, undo logs) at
another home directory, which is handy for rehearsing a sync against copies.

### `marksync browsers`

Lists Safari and every browser profile with a readable bookmark file, with counts.

```
safari
  bookmarks /Users/you/Library/Safari/Bookmarks.plist
  favorites 14
  sidebar   0
chrome
  chrome Default                 0     …/Google/Chrome/Default/Bookmarks
  chrome Profile 11 (account)    14    …/Google/Chrome/Profile 11/AccountBookmarks
```

### `marksync read`

Prints Safari's Favorites, sidebar and reading list. `--format json`, `--no-reading-list`.

### `marksync export`

| option | meaning |
|---|---|
| `--format html` | Netscape `bookmarks.html` — the universal format |
| `--format chromium` | Chrome/Edge/Brave `Bookmarks` JSON (drop it in as `<profile>/Bookmarks`) |
| `--format json` | this tool's own tree, for scripting |
| `--out, -o <path>` | write to a file instead of stdout |
| `--title <name>` | wrap everything in one folder |
| `--only <substr>` / `--exclude <substr>` | keep/drop folders by title (case-insensitive) |
| `--flatten` | drop all nesting |
| `--no-reading-list` | skip the reading list |

### `marksync import`

Adds a file's or another browser's bookmarks to Safari **in one folder** (use `sync` to merge
into matching places instead). Safari must be quit.

| option | meaning |
|---|---|
| `--source, -s <file>` | an HTML / Chromium-JSON / tree-JSON / Firefox `places.sqlite` file |
| `--browser, -b <name>` | read a browser's own file: `chrome edge brave chromium vivaldi opera arc firefox all` |
| `--title <name>` | container folder name (default `Imported <timestamp>`) |
| `--no-container` | add the items directly |
| `--favorites` | add to Favorites instead of the sidebar |
| `--dedupe` | skip URLs Safari already has |
| `--flatten` | drop all nesting |
| `--dry-run` / `--yes` | preview / skip the prompt |
| `--undo <log\|last>` | revert an import |

### `marksync convert`

Converts between formats without touching any browser.

```sh
marksync convert -s ~/edge-Bookmarks -t html -o ~/edge.html
marksync convert -s ~/edge.html -t json | jq '.bookmarks'
marksync convert -s ~/Library/Application\ Support/Firefox/Profiles/*/places.sqlite -t html
```

### `marksync profiles`, `marksync inspect`

Diagnostics for `SafariTabs.db`: Safari profiles (with their tab counts) and the private
`WebBookmarks` API surface. Not needed for syncing.

---

## Safari's `Bookmarks.plist`

```
root (WebBookmarkTypeList, Title "")
├── WebBookmarkTypeProxy    History — not a bookmark
├── BookmarksBar            Favorites · 个人收藏
├── BookmarksMenu           legacy bookmarks menu
├── com.apple.ReadingList   reading list
└── …                       folders and links at the top of the sidebar
```

Folders are `WebBookmarkTypeList` (`Title`, `Children`), links are `WebBookmarkTypeLeaf`
(`URLString`, `URIDictionary.title`); every item has a `WebBookmarkUUID`, and synced items carry
an iCloud `Sync` dictionary. When Safari finds Favorites empty it fills in its built-in sites
and sets `DidFillFavoritesBarWithBuiltInBookmarks` in its preferences.

`scripts/diagnose-safari.py` prints both stores' structure (counts and folder names only).

## Limitations

* `sync` is one-way per run and additive: deletions and moves are not propagated. Running it
  in both directions makes both sides hold the union, not a mirror.
* The reading list is not synced (Chromium keeps its reading list outside the `Bookmarks` file).
* Safari 17+ profiles can use a folder other than `BookmarksBar` as their Favorites; marksync
  always uses `BookmarksBar`, which is what the default profile shows.
* Firefox is read-only; use Firefox's own import to load an exported HTML file.

## Layout

```
Sources/MarkSyncCore/
  BookmarkTree.swift        browser-agnostic node/tree model
  BookmarkMerge.swift       slots (bar / other / mobile) and the additive merge planner
  SafariPlist.swift         Safari's Bookmarks.plist: read, append, remove by UUID
  ChromiumDocument.swift    editable Chromium Bookmarks file: ids, GUIDs, checksum
  SyncSupport.swift         profile discovery, running-app check, undo logs
  NetscapeHTML.swift        bookmarks.html reader + writer (tokenizer, entities)
  ChromiumBookmarks.swift   Chrome/Edge/Brave JSON reader + writer
  BrowserLocator.swift      finds browsers' bookmark files; format detection; Firefox reader
  SafariModel.swift         SafariTabs.db view (tabs, profiles) for diagnostics
  SafariBridge.swift        private WebBookmarks bridge, used only by diagnostics and old undo logs
  SQLite.swift              tiny read-only SQLite wrapper
  Output.swift              text/JSON rendering, filtering, dedupe, file output
Sources/marksync/           CLI (Marksync.swift: commands; Sync.swift: `sync`)
Sources/marksync-tests/     dependency-free test harness and suites (56 tests)
scripts/diagnose-safari.py  read-only look at Safari's stores
```

## License

[MIT](LICENSE) © 2026 jonty

marksync is an independent project and is not affiliated with or endorsed by Apple, Google,
Microsoft or any other browser vendor. Safari, Chrome and Edge are trademarks of their
respective owners. It edits your browsers' bookmark files directly: keep the backups it makes,
and use `--dry-run` first.
