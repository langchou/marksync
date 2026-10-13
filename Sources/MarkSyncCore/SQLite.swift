import Foundation
import SQLite3

/// Read-only SQLite access.
///
/// Safari holds a lock on its live database, so every query here opens with
/// `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` and never writes. We keep this tiny and
/// dependency-free (system `libsqlite3`) because the whole point of the tool is to work on a
/// stock macOS install with nothing else installed.
public enum SQLite {

    public enum Error: Swift.Error, CustomStringConvertible {
        case open(String, Int32)
        case prepare(String, Int32, String)
        case step(String, Int32, String)

        public var description: String {
            switch self {
            case .open(let p, let c): return "cannot open \(p) (\(c))"
            case .prepare(let s, let c, let m): return "prepare failed (\(c)): \(m) — \(s)"
            case .step(let s, let c, let m): return "step failed (\(c)): \(m) — \(s)"
            }
        }
    }

    /// Runs `sql` and returns each row as an array of optional strings.
    public static func rows(path: String, sql: String, bind: [String] = []) -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var out: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = sqlite3_column_count(stmt)
            var row: [String?] = []
            for c in 0..<n {
                if let p = sqlite3_column_text(stmt, c) {
                    row.append(String(cString: p))
                } else {
                    row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    public static func integers(path: String, sql: String) -> [Int] {
        rows(path: path, sql: sql).compactMap { $0.first.flatMap { $0 }.flatMap(Int.init) }
    }

    public static func strings(path: String, sql: String) -> [String] {
        rows(path: path, sql: sql).compactMap { $0.first.flatMap { $0 } }
    }

    /// `sqlite_master` entries.
    public static func schema(path: String) throws -> [String] {
        strings(path: path, sql: "select sql from sqlite_master where sql is not null order by type, name")
    }
}
