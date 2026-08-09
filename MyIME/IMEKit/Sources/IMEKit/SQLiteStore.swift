import CSQLite
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct StoreEntry: Sendable {
    public let id: Int64
    public let word: String
    public let pinyin: String
    public let weight: Int

    public init(id: Int64, word: String, pinyin: String, weight: Int) {
        self.id = id
        self.word = word
        self.pinyin = pinyin
        self.weight = weight
    }
}

public protocol CandidateLookup: Sendable {
    func lookup(pinyinKey: String, initials: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry]
    func lookupExact(pinyinKey: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry]
    func userBoost(word: String, pinyin: String) -> Double
    func unigramBoost(word: String) -> Double
    func bigramBoost(previous: String?, word: String) -> Double
    func sequenceBoost(prefix: String, word: String) -> Double
    func predictNext(after previous: String, limit: Int) -> [StoreEntry]
}

public extension CandidateLookup {
    func lookupExact(pinyinKey: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry] {
        lookup(pinyinKey: pinyinKey, initials: "", disabledSourceMask: disabledSourceMask, limit: limit)
            .filter { $0.pinyin.replacingOccurrences(of: "'", with: "") == pinyinKey }
    }

    func unigramBoost(word: String) -> Double { 0 }
    func sequenceBoost(prefix: String, word: String) -> Double { 0 }
    func predictNext(after previous: String, limit: Int) -> [StoreEntry] { [] }
}

public final class SQLiteStore: CandidateLookup, @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private var languageModel: [UInt64: Float] = [:]
    private var wordUnigrams: [UInt64: Float] = [:]
    private var wordBigrams: [UInt64: Float] = [:]
    private var predictions: [UInt64: [StoreEntry]] = [:]
    private var exactLookupCache: [String: [StoreEntry]] = [:]
    public let metadata: [String: String]
    public let traditionalConverter: TraditionalConverter

    public init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        database = handle
        sqlite3_exec(handle, "PRAGMA query_only=ON; PRAGMA busy_timeout=100;", nil, nil, nil)
        metadata = Self.readMetadata(handle)
        guard ["1", "2", "3", "4"].contains(metadata["schema_version"]) else {
            sqlite3_close(handle)
            database = nil
            return nil
        }
        languageModel = Self.readLanguageModel(handle)
        let wordModel = Self.readWordModel(handle)
        wordUnigrams = wordModel.unigrams
        wordBigrams = wordModel.bigrams
        predictions = wordModel.predictions
        traditionalConverter = Self.readTraditionalConverter(handle)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func integrityCheck() -> Bool {
        lock.withLock {
            guard let database else { return false }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else { return false }
            return String(cString: text) == "ok"
        }
    }

    public func lookup(pinyinKey: String, initials: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry] {
        lock.withLock {
            guard let database else { return [] }
            let sql = """
            SELECT id, word, pinyin, weight FROM entries
            WHERE (source_mask & ?1) != 0
              AND (py_key = ?2 OR py_key GLOB ?3 OR initials = ?4)
            ORDER BY CASE WHEN py_key = ?2 THEN 0 WHEN initials = ?4 THEN 1 ELSE 2 END,
                     weight DESC, word ASC, id ASC
            LIMIT ?5
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(statement, 1, Int64(~disabledSourceMask))
            bind(pinyinKey, to: statement, index: 2)
            bind(pinyinKey + "*", to: statement, index: 3)
            bind(initials, to: statement, index: 4)
            sqlite3_bind_int(statement, 5, Int32(limit))
            var values: [StoreEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let wordText = sqlite3_column_text(statement, 1),
                      let pinyinText = sqlite3_column_text(statement, 2) else { continue }
                values.append(StoreEntry(
                    id: sqlite3_column_int64(statement, 0),
                    word: String(cString: wordText),
                    pinyin: String(cString: pinyinText),
                    weight: Int(sqlite3_column_int(statement, 3))
                ))
            }
            return values
        }
    }

    public func lookupExact(pinyinKey: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry] {
        lock.withLock {
            guard let database else { return [] }
            let cacheKey = "\(disabledSourceMask)\u{0}\(limit)\u{0}\(pinyinKey)"
            if let cached = exactLookupCache[cacheKey] { return cached }
            let sql = """
            SELECT id, word, pinyin, weight FROM entries
            WHERE (source_mask & ?1) != 0 AND py_key = ?2
            ORDER BY weight DESC, word ASC, id ASC LIMIT ?3
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(statement, 1, Int64(~disabledSourceMask))
            bind(pinyinKey, to: statement, index: 2)
            sqlite3_bind_int(statement, 3, Int32(limit))
            var values: [StoreEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let word = sqlite3_column_text(statement, 1),
                  let pinyin = sqlite3_column_text(statement, 2) {
                values.append(StoreEntry(
                    id: sqlite3_column_int64(statement, 0),
                    word: String(cString: word),
                    pinyin: String(cString: pinyin),
                    weight: Int(sqlite3_column_int(statement, 3))
                ))
            }
            if exactLookupCache.count >= 1_024 { exactLookupCache.removeAll(keepingCapacity: true) }
            exactLookupCache[cacheKey] = values
            return values
        }
    }

    public func userBoost(word: String, pinyin: String) -> Double { 0 }

    public func unigramBoost(word: String) -> Double {
        Double(wordUnigrams[Self.stableHash(word)] ?? 0)
    }

    public func bigramBoost(previous: String?, word: String) -> Double {
        guard let previous, !previous.isEmpty else { return 0 }
        return Double(wordBigrams[Self.stableHash(previous + "\u{0}" + word)] ?? 0)
    }

    public func predictNext(after previous: String, limit: Int) -> [StoreEntry] {
        guard !previous.isEmpty, limit > 0 else { return [] }
        let values = predictions[Self.stableHash(previous)] ?? []
        return Array(values.prefix(limit))
    }

    public func sequenceBoost(prefix: String, word: String) -> Double {
        guard !prefix.isEmpty, !word.isEmpty, !languageModel.isEmpty else { return 0 }
        let left = String(prefix.suffix(2))
        let right = String(word.prefix(2))
        let combined = Array(left + right)
        let boundary = left.count
        var score = 0.0
        for order in 3...3 where combined.count >= order {
            for start in 0...(combined.count - order) where start < boundary && start + order > boundary {
                let ngram = String(combined[start..<(start + order)])
                score += Double(languageModel[Self.stableHash(ngram)] ?? 0) * 1.4
            }
        }
        return score
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func readLanguageModel(_ database: OpaquePointer) -> [UInt64: Float] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT ngram,score FROM language_ngram", -1, &statement, nil) == SQLITE_OK else { return [:] }
        var result: [UInt64: Float] = [:]
        while sqlite3_step(statement) == SQLITE_ROW,
              let ngram = sqlite3_column_text(statement, 0) {
            result[stableHash(String(cString: ngram))] = Float(sqlite3_column_double(statement, 1))
        }
        return result
    }

    private static func readWordModel(_ database: OpaquePointer) -> (
        unigrams: [UInt64: Float],
        bigrams: [UInt64: Float],
        predictions: [UInt64: [StoreEntry]]
    ) {
        var unigrams: [UInt64: Float] = [:]
        var bigrams: [UInt64: Float] = [:]
        var predictions: [UInt64: [StoreEntry]] = [:]

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT word,score FROM word_unigram", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW,
                  let word = sqlite3_column_text(statement, 0) {
                unigrams[stableHash(String(cString: word))] = Float(sqlite3_column_double(statement, 1))
            }
        }
        sqlite3_finalize(statement)

        statement = nil
        if sqlite3_prepare_v2(
            database,
            "SELECT prev,word,score FROM word_bigram ORDER BY prev ASC, score DESC, word ASC",
            -1,
            &statement,
            nil
        ) == SQLITE_OK {
            var predictionID: Int64 = -1
            while sqlite3_step(statement) == SQLITE_ROW,
                  let previousText = sqlite3_column_text(statement, 0),
                  let wordText = sqlite3_column_text(statement, 1) {
                let previous = String(cString: previousText)
                let word = String(cString: wordText)
                let score = Float(sqlite3_column_double(statement, 2))
                bigrams[stableHash(previous + "\u{0}" + word)] = score
                guard word.count >= 2 else { continue }
                let key = stableHash(previous)
                var bucket = predictions[key] ?? []
                if bucket.count < 12 {
                    predictionID -= 1
                    bucket.append(StoreEntry(
                        id: predictionID,
                        word: word,
                        pinyin: "",
                        weight: Int((score * 65_535).rounded())
                    ))
                    predictions[key] = bucket
                }
            }
        }
        sqlite3_finalize(statement)
        return (unigrams, bigrams, predictions)
    }

    private static func readMetadata(_ database: OpaquePointer) -> [String: String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT key, value FROM meta", -1, &statement, nil) == SQLITE_OK else { return [:] }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW,
              let key = sqlite3_column_text(statement, 0),
              let value = sqlite3_column_text(statement, 1) {
            result[String(cString: key)] = String(cString: value)
        }
        return result
    }

    private static func readTraditionalConverter(_ database: OpaquePointer) -> TraditionalConverter {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT simplified,traditional FROM traditional_map", -1, &statement, nil) == SQLITE_OK else {
            return .empty
        }
        var mappings: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW,
              let simplified = sqlite3_column_text(statement, 0),
              let traditional = sqlite3_column_text(statement, 1) {
            mappings[String(cString: simplified)] = String(cString: traditional)
        }
        return TraditionalConverter(mappings: mappings)
    }
}

public final class UserStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fudan.miniS.MyIME.user-store", qos: .utility)
    private let lock = NSLock()
    private var database: OpaquePointer?

    public init?(path: String) {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        database = handle
        let schema = """
        PRAGMA journal_mode=WAL; PRAGMA busy_timeout=1000;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        INSERT OR IGNORE INTO meta VALUES('schema_version','1');
        CREATE TABLE IF NOT EXISTS user_freq(word TEXT, pinyin TEXT, count INTEGER, last_used INTEGER, PRIMARY KEY(word,pinyin));
        CREATE TABLE IF NOT EXISTS user_phrase(word TEXT, pinyin TEXT, weight INTEGER, created INTEGER, PRIMARY KEY(word,pinyin));
        CREATE TABLE IF NOT EXISTS bigram(prev TEXT, word TEXT, count INTEGER, PRIMARY KEY(prev,word));
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            database = nil
            return nil
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func learn(word: String, pinyin: String, previous: String?) {
        queue.async { [weak self] in
            self?.lock.withLock {
                guard let database = self?.database else { return }
                sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
                var statement: OpaquePointer?
                let frequencySQL = """
                INSERT INTO user_freq(word,pinyin,count,last_used) VALUES(?1,?2,1,?3)
                ON CONFLICT(word,pinyin) DO UPDATE SET count=count+1,last_used=excluded.last_used
                """
                if sqlite3_prepare_v2(database, frequencySQL, -1, &statement, nil) == SQLITE_OK {
                    bind(word, to: statement, index: 1)
                    bind(pinyin, to: statement, index: 2)
                    sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970))
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
                if let previous, !previous.isEmpty {
                    statement = nil
                    let bigramSQL = """
                    INSERT INTO bigram(prev,word,count) VALUES(?1,?2,1)
                    ON CONFLICT(prev,word) DO UPDATE SET count=count+1
                    """
                    if sqlite3_prepare_v2(database, bigramSQL, -1, &statement, nil) == SQLITE_OK {
                        bind(previous, to: statement, index: 1)
                        bind(word, to: statement, index: 2)
                        sqlite3_step(statement)
                    }
                    sqlite3_finalize(statement)
                }
                sqlite3_exec(database, "COMMIT", nil, nil, nil)
            }
        }
    }

    public func learnPhrase(word: String, pinyin: String) {
        guard word.count > 1, !pinyin.isEmpty else { return }
        lock.withLock {
            guard let database else { return }
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO user_phrase(word,pinyin,weight,created) VALUES(?1,?2,4096,?3)
            ON CONFLICT(word,pinyin) DO UPDATE SET
                weight=min(65535,weight+4096),created=excluded.created
            """
            if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK {
                bind(word, to: statement, index: 1)
                bind(pinyin, to: statement, index: 2)
                sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    public func lookup(pinyinKey: String, initials: String, limit: Int) -> [StoreEntry] {
        lock.withLock {
            guard let database else { return [] }
            let now = Int64(Date().timeIntervalSince1970)
            let sql = """
            SELECT rowid,word,pinyin,weight,created FROM user_phrase
            ORDER BY min(65535,weight + CASE
                WHEN ?1-created <= 300 THEN 32768
                WHEN ?1-created <= 3600 THEN 16384
                WHEN ?1-created <= 86400 THEN 4096
                ELSE 0 END) DESC,word ASC,rowid ASC LIMIT 500
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(statement, 1, now)
            var entries: [StoreEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let word = sqlite3_column_text(statement, 1),
                  let pinyin = sqlite3_column_text(statement, 2) {
                let pinyinValue = String(cString: pinyin)
                let parts = pinyinValue.split(separator: "'")
                let key = parts.joined()
                let entryInitials = parts.compactMap(\.first).map(String.init).joined()
                guard key.hasPrefix(pinyinKey) || entryInitials == initials else { continue }
                let age = max(0, Double(now - sqlite3_column_int64(statement, 4)))
                let recencyBonus = age <= 300 ? 32_768 : age <= 3_600 ? 16_384 : age <= 86_400 ? 4_096 : 0
                entries.append(StoreEntry(
                    id: -sqlite3_column_int64(statement, 0),
                    word: String(cString: word),
                    pinyin: pinyinValue,
                    weight: min(65_535, Int(sqlite3_column_int(statement, 3)) + recencyBonus)
                ))
                if entries.count == limit { break }
            }
            return entries
        }
    }

    public func lookupExact(pinyinKey: String, limit: Int) -> [StoreEntry] {
        lookup(pinyinKey: pinyinKey, initials: "", limit: limit)
            .filter { $0.pinyin.replacingOccurrences(of: "'", with: "") == pinyinKey }
    }

    public func boost(word: String, pinyin: String) -> Double {
        guard let values = integerRow(
            sql: "SELECT count,last_used FROM user_freq WHERE word=?1 AND pinyin=?2",
            values: [word, pinyin]
        ) else { return 0 }
        let age = max(0, Date().timeIntervalSince1970 - Double(values[1]))
        let recency = age <= 300 ? 0.25 : age <= 3_600 ? 0.12 : age <= 86_400 ? 0.05 : 0
        return log1p(Double(values[0])) / 10.0 + recency
    }

    public func bigram(previous: String?, word: String) -> Double {
        guard let previous else { return 0 }
        return scalar(sql: "SELECT count FROM bigram WHERE prev=?1 AND word=?2", values: [previous, word])
            .map { min(4, log1p(Double($0))) } ?? 0
    }

    public func predictNext(after previous: String, limit: Int) -> [StoreEntry] {
        guard !previous.isEmpty, limit > 0 else { return [] }
        return lock.withLock {
            guard let database else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = """
            SELECT word,count FROM bigram
            WHERE prev=?1 AND length(word) >= 2
            ORDER BY count DESC, word ASC
            LIMIT ?2
            """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            bind(previous, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var entries: [StoreEntry] = []
            var rowID: Int64 = -1
            while sqlite3_step(statement) == SQLITE_ROW,
                  let word = sqlite3_column_text(statement, 0) {
                rowID -= 1
                let count = Int(sqlite3_column_int(statement, 1))
                entries.append(StoreEntry(
                    id: rowID,
                    word: String(cString: word),
                    pinyin: "",
                    weight: min(65_535, 8_000 + count * 4_000)
                ))
            }
            return entries
        }
    }

    public func importTSV(from url: URL, validSyllables: Set<String> = PinyinTable.syllables) -> (imported: Int, rejected: Int) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return (0, 1) }
        var accepted: [(String, String, Int)] = []
        var rejected = 0
        for line in content.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let weight = Int(fields[2]), weight >= 0 else { rejected += 1; continue }
            let word = String(fields[0]).precomposedStringWithCanonicalMapping
            let pinyin = String(fields[1]).lowercased()
            let parts = pinyin.split(separator: "'").map(String.init)
            guard !word.isEmpty, word.count <= 20, !parts.isEmpty,
                  parts.allSatisfy(validSyllables.contains),
                  pinyin.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }) else {
                rejected += 1
                continue
            }
            accepted.append((word, pinyin, weight))
        }
        lock.withLock {
            guard let database else { return }
            sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
            for (word, pinyin, weight) in accepted {
                var statement: OpaquePointer?
                let sql = """
                INSERT INTO user_phrase(word,pinyin,weight,created) VALUES(?1,?2,?3,?4)
                ON CONFLICT(word,pinyin) DO UPDATE SET weight=max(weight,excluded.weight)
                """
                if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK {
                    bind(word, to: statement, index: 1)
                    bind(pinyin, to: statement, index: 2)
                    sqlite3_bind_int(statement, 3, Int32(clamping: weight))
                    sqlite3_bind_int64(statement, 4, Int64(Date().timeIntervalSince1970))
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
            }
            sqlite3_exec(database, "COMMIT", nil, nil, nil)
        }
        return (accepted.count, rejected)
    }

    public func exportTSV(to url: URL) throws {
        let text = lock.withLock { () -> String in
            guard let database else { return "" }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT word,pinyin,weight FROM user_phrase ORDER BY word,pinyin", -1, &statement, nil) == SQLITE_OK else { return "" }
            var lines: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW,
                  let word = sqlite3_column_text(statement, 0),
                  let pinyin = sqlite3_column_text(statement, 1) {
                lines.append("\(String(cString: word))\t\(String(cString: pinyin))\t\(sqlite3_column_int(statement, 2))")
            }
            return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func clearLearning() {
        queue.async { [weak self] in
            self?.lock.withLock {
                guard let database = self?.database else { return }
                sqlite3_exec(database, "DELETE FROM user_freq; DELETE FROM bigram;", nil, nil, nil)
            }
        }
    }

    public func waitForPendingWrites() {
        queue.sync {}
    }

    private func scalar(sql: String, values: [String]) -> Int? {
        lock.withLock {
            guard let database else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            for (offset, value) in values.enumerated() { bind(value, to: statement, index: Int32(offset + 1)) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func integerRow(sql: String, values: [String]) -> [Int64]? {
        lock.withLock {
            guard let database else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            for (offset, value) in values.enumerated() { bind(value, to: statement, index: Int32(offset + 1)) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (0..<sqlite3_column_count(statement)).map { sqlite3_column_int64(statement, $0) }
        }
    }
}

private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
    _ = value.withCString { pointer in
        sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
    }
}
