import Foundation
import SafariBookmarksCore

let suites: [(String, [TestCase])] = [
    ("NetscapeHTML", NetscapeHTMLSuite.all),
    ("ChromiumBookmarks", ChromiumBookmarksSuite.all),
    ("Firefox", FirefoxSuite.all),
    ("FormatDetection", FormatDetectionSuite.all),
    ("Filtering", FilteringSuite.all),
    ("Dedupe", DedupeSuite.all),
    ("JSONTree", JSONTreeSuite.all),
    ("Serialize", SerializeSuite.all),
    ("SafariModel", SafariModelSuite.all),
    ("SQLite", SQLiteSuite.all),
]

exit(runTests(suites))
