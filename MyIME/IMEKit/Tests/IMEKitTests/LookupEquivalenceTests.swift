import Foundation
import SQLite3
import Testing
@testable import IMEKit

@Suite("LookupEquivalence") struct LookupEquivalenceTests {
    /// The tiered lookup must return exactly what the former single OR/GLOB query returned
    /// (same rows, same order) for full, prefix, abbreviation and masked queries.
    @Test func tieredLookupMatchesLegacyQuery() throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = ProcessInfo.processInfo.environment["MYIME_TEST_SYSTEM_DATABASE"]
            ?? packageDirectory.appending(path: "../MyIME/Resources/system.sqlite").standardizedFileURL.path
        let store = try #require(SQLiteStore(path: path))
        let queries: [(key: String, initials: String)] = [
            ("xia", "xia"), ("xian", "xian"), ("xi", "xi"), ("x", "x"), ("bj", "bj"), ("beij", ""),
            ("nihao", ""), ("tianqi", ""), ("zhongguo", ""), ("sj", "sj"), ("wo", ""), ("de", "de"),
            ("zzzz", "zzzz"), ("", ""), ("shi", "shi"), ("yinhang", "yh"), ("a", "a"),
        ]
        for mask in [0, 1, 2, 5] {
            for limit in [1, 10, 30, 100] {
                for query in queries {
                    let new = store.lookup(pinyinKey: query.key, initials: query.initials, disabledSourceMask: mask, limit: limit)
                    let old = Self.legacyIDs(path: path, key: query.key, initials: query.initials, mask: mask, limit: limit)
                    #expect(new.map(\.id) == old, "key=\(query.key) initials=\(query.initials) mask=\(mask) limit=\(limit)")
                }
            }
        }
    }

    /// The pre-optimisation query, verbatim, run on its own read-only connection.
    private static func legacyIDs(path: String, key: String, initials: String, mask: Int, limit: Int) -> [Int64] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        let sql = """
        SELECT id FROM entries
        WHERE (source_mask & ?1) != 0
          AND (py_key = ?2 OR py_key GLOB ?3 OR initials = ?4)
        ORDER BY CASE WHEN py_key = ?2 THEN 0 WHEN initials = ?4 THEN 1 ELSE 2 END,
                 weight DESC, word ASC, id ASC
        LIMIT ?5
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, Int64(~mask))
        sqlite3_bind_text(statement, 2, key, -1, transient)
        sqlite3_bind_text(statement, 3, key + "*", -1, transient)
        sqlite3_bind_text(statement, 4, initials, -1, transient)
        sqlite3_bind_int(statement, 5, Int32(limit))
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
        return ids
    }
}
