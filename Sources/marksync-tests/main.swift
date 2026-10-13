import Foundation
import MarkSyncCore

// Unbuffered so output survives a crash inside a test.
setvbuf(stdout, nil, _IONBF, 0)

let suites: [(String, [TestCase])] = [
    ("NetscapeHTML", NetscapeHTMLSuite.all),
    ("ChromiumBookmarks", ChromiumBookmarksSuite.all),
    ("Firefox", FirefoxSuite.all),
    ("BrowserLocator", BrowserLocatorSuite.all),
    ("ChromiumProfiles", ChromiumProfileSuite.all),
    ("ChromiumDocument", ChromiumDocumentSuite.all),
    ("Sync", SyncSuite.all),
    ("SafariPlist", SafariPlistSuite.all),
    ("FormatDetection", FormatDetectionSuite.all),
    ("Filtering", FilteringSuite.all),
    ("Dedupe", DedupeSuite.all),
    ("JSONTree", JSONTreeSuite.all),
    ("Serialize", SerializeSuite.all),
    ("SafariModel", SafariModelSuite.all),
    ("SQLite", SQLiteSuite.all),
]

exit(runTests(suites))
