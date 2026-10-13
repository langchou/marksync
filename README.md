# safaribm

Move bookmarks **into** and **out of** Safari on macOS — including the parts Safari's own
export/import cannot reach.

```
safaribm export --format html  --out ~/Desktop/safari-bookmarks.html   # Safari → any browser
safaribm export --format chromium --out ~/Bookmarks                    # Safari → Chrome/Edge/Brave
safaribm import --browser edge --dry-run                               # preview
safaribm import --browser edge --yes                                   # Edge → Safari
safaribm convert -s ~/edge-Bookmarks -t html -o ~/edge.html            # no Safari involved
```

No dependencies. Pure Swift, system SQLite, one private framework call for writes.

---

## Why this exists

Safari's bookmark storage changed completely in Safari 17 and has been moving ever since:

| | where bookmarks live |
|---|---|
| Safari ≤ 16 | `~/Library/Safari/Bookmarks.plist` (a binary plist you could parse) |
| Safari 17+ | `~/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db` (SQLite) |
| Safari 26 | the same SQLite file, now also holding tab groups, profiles and windows |

The `Bookmarks.plist` at `~/Library/Safari/` still exists on a modern Mac but is **empty** — it
only carries the CloudKit sync metadata. Every tool that reads that file reports "no bookmarks".

Safari also has no scripting dictionary, so AppleScript cannot enumerate bookmarks, and
`~/Library/Safari/AutomaticBookmarksBackup.html` is empty for the same reason.

This tool reads and writes the real store.

---

## Install

Requires macOS 14+ and the Xcode **Command Line Tools** (`xcode-select --install`). No Xcode,
no package dependencies.

```sh
git clone <this repo> && cd open-safari
swift build -c release
sudo cp .build/release/safaribm /usr/local/bin/       # optional
```

Run the test suite (38 tests, no XCTest needed):

```sh
swift run safaribm-tests
```

---

## Commands

### `safaribm browsers`

Lists every browser on this Mac that has a readable bookmark file, plus Safari's profiles.

```
safari
  database  /Users/you/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db
  profile   #44 'Default'  1 bookmarks
edge
  edge Default  /Users/you/Library/Application Support/Microsoft Edge/Default/Bookmarks
```

### `safaribm profiles`

```
database: /Users/you/Library/Containers/com.apple.Safari/Data/Library/Safari/SafariTabs.db
  #44   Default                      1 links    0 folders
```

### `safaribm read`

Prints Safari's bookmark tree. `--format json`, `--profile <name|id>`, `--hidden`,
`--reading-list`, `--db <path>` (read a copy instead of the live database).

### `safaribm export`

| option | meaning |
|---|---|
| `--format html` | Netscape `bookmarks.html` — the universal format |
| `--format chromium` | Chrome/Edge/Brave `Bookmarks` JSON (drop it in as `<profile>/Bookmarks`) |
| `--format json` | this tool's own tree, for scripting |
| `--out, -o <path>` | write to a file instead of stdout |
| `--profile <name\|id>` | export a single Safari profile |
| `--title <name>` | wrap everything in one folder |
| `--only <substr>` / `--exclude <substr>` | keep/drop folders by title (case-insensitive) |
| `--flatten` | drop all nesting |
| `--no-reading-list` | skip the reading list |

```sh
# Everything Safari has, for Firefox/Chrome/Safari-on-another-Mac
safaribm export --format html --out ~/Desktop/safari.html

# Just the "C++" folder, flattened
safaribm export --format html --only "c++" --flatten --out ~/cpp.html

# A ready-to-drop-in Chromium profile file
safaribm export --format chromium --out "/tmp/Bookmarks"
```

### `safaribm import`

| option | meaning |
|---|---|
| `--source, -s <file>` | an HTML / Chromium-JSON / tree-JSON / Firefox `places.sqlite` file |
| `--browser, -b <name>` | read a browser's own file: `chrome edge brave chromium vivaldi opera arc firefox all` |
| `--profile <name\|id>` | Safari profile to import into (default: the active one) |
| `--parent <id>` | explicit destination folder id |
| `--title <name>` | container folder name (default `Imported <timestamp>`) |
| `--no-container` | import straight into the destination folder |
| `--dedupe` | skip URLs already present at the destination |
| `--flatten` | drop all nesting |
| `--dry-run` | print what would happen, write nothing |
| `--yes` | skip the confirmation prompt |
| `--undo <folderID>` | delete a folder created by an earlier import |

```sh
safaribm import --browser edge --dry-run           # look first
safaribm import --browser edge --yes               # then do it
safaribm import --browser all --dedupe --yes       # every browser, skipping duplicates
safaribm import --undo 52                          # revert that import
```

An import is **transactional per import**: if any item fails, the container folder it created is
deleted again, so a failed import never leaves a half-written tree.

### `safaribm convert`

Converts between formats without touching Safari — useful for moving Edge → Firefox, or for
inspecting what an import would contain.

```sh
safaribm convert -s ~/edge-Bookmarks -t html -o ~/edge.html
safaribm convert -s ~/edge.html -t json | jq '.bookmarks'
safaribm convert -s ~/Library/Application\ Support/Firefox/Profiles/*/places.sqlite -t html
```

Supported input formats are auto-detected: Netscape HTML, Chromium JSON, this tool's own tree
JSON, and Firefox's `places.sqlite`.

### `safaribm inspect`

Dumps the reverse-engineering surface: `paths`, `api` (private classes and their exact method
type encodings), `schema` (the `bookmarks` table), `db` (a row-level dump), `all`.

---

## How it works

Everything below was recovered by inspecting `WebBookmarks.framework`, `SafariShared.framework`
and the on-disk database. `safaribm inspect api` prints the live table of selectors and their
type encodings.

### Reads: SQLite

Reads go straight to `SafariTabs.db` in read-only mode. The private framework is *not* used for
reads, deliberately:

> `WebBookmarkCollection` honours the `com.apple.bookmarks.OmitFromUI` extra attribute and hides
> every folder carrying it. On a stock macOS 26 install **all profile folders carry it**, so
> `-listWithID:` — and even `-listWithID:skipOffset:includeHidden:YES` — reports the collection
> root as having two children (the bookmarks bar and the reading list) while the database holds
> several profiles full of bookmarks. Reading the table directly is both simpler and strictly
> more complete.

The store's shape:

| what the user sees | how it is stored |
|---|---|
| bookmarks bar | root child folder titled `BookmarksBar` |
| bookmarks menu | `BookmarksMenu` (legacy, usually absent) |
| reading list | root child folder titled `com.apple.ReadingList` |
| a profile | a **hidden root folder** (`parent is null`, *not* `parent = 0`) holding a `com.apple.Bookmark` › `DateAdded` blob, plus a hidden `Private` sibling |
| tab groups / pinned tabs | hidden root folders `pinned`, `privatePinned`, `recentlyClosed` |
| Safari ≤ 16 layout | one folder with `subtype = 2` holding everything |

Three details cost real time to find:

1. **Profile folders have `parent is null`.** They are not children of the root row, so
   `listWithID: 0` never returns them and `folder_ancestors` never mentions them.
2. **The `special_id` column is almost always 0.** The framework resolves special folders by
   *title* — `-_databaseTitleForSpecialID:` maps `1 → BookmarksBar`, `2 → BookmarksMenu`,
   `3 → com.apple.ReadingList`, `4 → com.apple.WebFilterWhiteList`,
   `5 → com.apple.FrequentlyVisitedSites`, `6 → Recovered`. Only `Recovered` actually had its
   column populated. The `BookmarksBarSpecialID`-style globals are packed `(kind << 32) | id`,
   so the useful value is the low 32 bits.
3. **`extra_attributes` is a BLOB.** Reading it with `sqlite3_column_text` truncates at the first
   NUL byte and the profile date is silently lost. It must be read as `hex(extra_attributes)` and
   decoded as an `NSKeyedArchiver` property list.

Profile *names* are not in the database at all — the folder titles are the literal placeholders
`Local` / `Private`. The display name comes from `SafariProfilesLastActiveProfileUUIDString` in
Safari's preferences (`DefaultProfile` → "Default"). A machine that has recreated its Safari
container can end up with several such folders, so duplicate names are suffixed with the folder id.

### Writes: `WebBookmarks`

Writes go through the framework, because only it maintains `dav_generation`, the sync metadata,
the ancestor table and child counters. Two behaviours had to be worked around:

* `-mergeWithBookmarksDictionary:clearHidden:clearSyncData:error:` always appends its top-level
  children to the **collection root**, where Safari never shows them. It is therefore not used
  for imports; `WebBookmark` + `-saveBookmark:` is used instead, which lets us choose the
  destination folder and gives per-item failure detection.
* `-initFolderWithParentID:subtype:collectionType:` takes no title, and
  `-initWithTitle:address:parentID:folder:collectionType:` does not always stick its label —
  `-setTitle:` has to be called explicitly afterwards.

Note that `NSInvocation` and `NSMethodSignature` are unavailable in Swift, so every call is an
`unsafeBitCast`ed `@convention(c)` closure whose signature is taken from
`method_getTypeEncoding`. See `Sources/SafariBookmarksCore/SafariBridge.swift`.

---

## Safety

* **Reads never modify anything.** All queries open the database `SQLITE_OPEN_READONLY`.
* **Back up before writing.** Safari keeps its own CloudKit sync state in this file:
  ```sh
  cp -R ~/Library/Containers/com.apple.Safari/Data/Library/Safari ~/safari-backup
  ```
* **Writes need write access** to `SafariTabs.db`. A normal terminal has it; if you see
  *"is not writable"*, grant Full Disk Access to your terminal in
  System Settings › Privacy & Security › Full Disk Access.
* **Safari can be running.** New bookmarks are committed to the database immediately; Safari is
  asked to reload via the `WebBookmarksDidReload` distributed notification. If the sidebar does
  not refresh, quit and reopen Safari (⌘Q) — the change is already on disk.
* **Every import is reversible**: it prints the container folder id, and
  `safaribm import --undo <id>` deletes that subtree.
* `--dry-run` on any import tells you exactly what would be written.

## Limitations

* Reading list archives (the saved offline copies) are not exported — only the entries.
* iCloud-synced changes made on another device are not merged; the tool reads the local store.
* The legacy `Bookmarks.plist` path (Safari ≤ 16) is detected but not parsed — that format needs
  a `Bookmarks.plist`-specific reader.
* Firefox reading is read-only and one-way (there is no Firefox writer); use Firefox's own
  import to load an exported HTML file.
* Only one Safari profile can be a destination per import; run the command once per profile.

## Layout

```
Sources/SafariBookmarksCore/
  BookmarkTree.swift        browser-agnostic node/tree model
  NetscapeHTML.swift        bookmarks.html reader + writer (tokenizer, entities)
  ChromiumBookmarks.swift   Chrome/Edge/Brave JSON reader + writer
  BrowserLocator.swift      finds browsers' bookmark files; format detection; Firefox reader
  SafariModel.swift         read-only SQLite view: profiles, special folders, tree building
  SafariBridge.swift        reverse-engineered WebBookmarks bridge (writes) + ObjC runtime glue
  SQLite.swift              tiny read-only SQLite wrapper
  Output.swift              text/JSON rendering, filtering, dedupe, file output
Sources/safaribm/main.swift CLI
Sources/safaribm-tests/     dependency-free test harness and suites (38 tests)
```
