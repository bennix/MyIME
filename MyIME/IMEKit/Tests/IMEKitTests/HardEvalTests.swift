import Foundation
import Testing
@testable import IMEKit

/// Independent benchmark the ranking was not tuned against: everyday chat, office,
/// written and homophone-heavy sentences plus modern vocabulary, and the latency of
/// typing those sentences one key at a time.
@Suite("HardEval", .serialized) struct HardEvalTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    private static func rows(_ name: String) throws -> [[String]] {
        try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t").map(String.init) }
    }

    private static func bundledStore() throws -> SQLiteStore {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let databasePath = ProcessInfo.processInfo.environment["MYIME_TEST_SYSTEM_DATABASE"]
            ?? packageDirectory.appending(path: "../MyIME/Resources/system.sqlite").standardizedFileURL.path
        return try #require(SQLiteStore(path: databasePath))
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    /// Returns (sentence top-1 accuracy, character accuracy) over a `category\tpinyin\texpected` fixture.
    private static func evaluate(_ file: String, label: String, engine: Engine) throws -> (sentence: Double, character: Double) {
        let prefs = EnginePrefs()
        var hits: [String: (hit: Int, total: Int)] = [:]
        var sentenceHits = 0, sentenceTotal = 0, charHits = 0, charTotal = 0
        for row in try rows(file) {
            let (category, input, expected) = (row[0], row[1], row[2])
            let top = engine.update(input, prefs: prefs).candidates.first?.word ?? ""
            let correct = top == expected
            hits[category, default: (0, 0)].total += 1
            if correct { hits[category, default: (0, 0)].hit += 1 }
            sentenceTotal += 1
            sentenceHits += correct ? 1 : 0
            charTotal += expected.count
            charHits += top.count == expected.count ? zip(top, expected).filter { $0 == $1 }.count : 0
            if !correct { print("  MISS[\(label)/\(category)] \(input) → 期望 \(expected), 实得 \(top)") }
        }
        for (category, value) in hits.sorted(by: { $0.key < $1.key }) {
            print("\(label)[整句/\(category)] top1: \(value.hit)/\(value.total) = \(percent(Double(value.hit) / Double(value.total)))")
        }
        let sentenceAccuracy = Double(sentenceHits) / Double(sentenceTotal)
        let charAccuracy = Double(charHits) / Double(charTotal)
        print("\(label)[整句] top1: \(sentenceHits)/\(sentenceTotal) = \(percent(sentenceAccuracy)), 字准确率 \(percent(charAccuracy))")
        return (sentenceAccuracy, charAccuracy)
    }

    /// Clauses sampled from public web corpora by `tools/build_web_eval.py`. `web_dev.tsv` is
    /// the set ranking changes are tuned on; `web_test.tsv` is held out to expose overfitting.
    @Test(arguments: ["web_dev", "web_test"]) func webCorpus(name: String) throws {
        let result = try Self.evaluate("\(name).tsv", label: name == "web_dev" ? "WEBDEV" : "WEBTEST", engine: Engine(store: try Self.bundledStore()))
        // Regression floors set a little under the measured values (labels are pypinyin/jieba
        // agreement, not ground truth, so these guard against regressions, not absolute quality).
        #expect(result.sentence >= 0.49, "\(name) top1 \(result.sentence)")
        #expect(result.character >= 0.85, "\(name) chars \(result.character)")
    }

    /// Optional: scores the engine on the exact rows of an externally produced reference file
    /// (`category\tpinyin\texpected\treferenceTop1`, e.g. the 500-row Google Input Tools sample kept
    /// outside the repository). Set `MYIME_REFERENCE_TSV`; skipped when unset.
    @Test func referenceComparison() throws {
        guard let path = ProcessInfo.processInfo.environment["MYIME_REFERENCE_TSV"] else { return }
        let engine = Engine(store: try Self.bundledStore())
        let prefs = EnginePrefs()
        var total = 0, ours = 0, theirs = 0, ourChars = 0, theirChars = 0, chars = 0
        func matches(_ a: String, _ b: String) -> Int { a.count == b.count ? zip(a, b).filter { $0 == $1 }.count : 0 }
        for line in try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let row = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard row.count >= 4 else { continue }
            let top = engine.update(row[1], prefs: prefs).candidates.first?.word ?? ""
            total += 1; chars += row[2].count
            ours += top == row[2] ? 1 : 0; theirs += row[3] == row[2] ? 1 : 0
            ourChars += matches(top, row[2]); theirChars += matches(row[3], row[2])
        }
        print("REF[同样本] n=\(total) 本引擎 top1 \(ours) = \(Self.percent(Double(ours) / Double(total))) 字 \(Self.percent(Double(ourChars) / Double(chars))); 参考 top1 \(theirs) = \(Self.percent(Double(theirs) / Double(total))) 字 \(Self.percent(Double(theirChars) / Double(chars)))")
    }

    @Test func sentencesAndWords() throws {
        let engine = Engine(store: try Self.bundledStore())
        let prefs = EnginePrefs()
        let hard = try Self.evaluate("hard_sentences.tsv", label: "HARD", engine: engine)
        #expect(hard.sentence >= 0.78, "hard top1 \(hard.sentence)")
        #expect(hard.character >= 0.95, "hard chars \(hard.character)")

        var top1 = 0, top3 = 0
        let words = try Self.rows("hard_words.tsv")
        for row in words {
            let candidates = engine.update(row[0], prefs: prefs).candidates.prefix(3).map(\.word)
            if candidates.first == row[1] { top1 += 1 }
            if candidates.contains(row[1]) { top3 += 1 } else { print("  MISS[词] \(row[0]) → 期望 \(row[1]), 实得 \(candidates.joined(separator: "/"))") }
        }
        let wordTop1 = Double(top1) / Double(words.count)
        let wordTop3 = Double(top3) / Double(words.count)
        print("HARD[词] top1: \(top1)/\(words.count) = \(Self.percent(wordTop1)), top3: \(top3)/\(words.count) = \(Self.percent(wordTop3))")
        #expect(wordTop1 >= 0.93, "hard word top1 \(wordTop1)")
        #expect(wordTop3 >= 0.97, "hard word top3 \(wordTop3)")
    }

    @Test func incrementalTypingLatency() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "myime-hard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let userStore = try #require(UserStore(path: directory.appending(path: "user.sqlite").path))
        let engine = Engine(store: try Self.bundledStore(), userStore: userStore)
        let prefs = EnginePrefs()
        let sentences = try Self.rows("hard_sentences.tsv")
        // A realistic learned profile: the user has typed these sentences' words before.
        for row in sentences.prefix(60) {
            engine.commitLearning(word: row[2], pinyin: [row[1]])
            userStore.learnPhrase(word: row[2], pinyin: row[1])
        }
        userStore.waitForPendingWrites()

        let clock = ContinuousClock()
        var samples: [Double] = []
        for row in sentences {
            var typed = ""
            for letter in row[1] {
                typed.append(letter)
                let elapsed = clock.measure { _ = engine.update(typed, prefs: prefs) }
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
            }
        }
        samples.sort()
        func quantile(_ q: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * q))] }
        let mean = samples.reduce(0, +) / Double(samples.count)
        print(String(
            format: "HARD[逐键延迟] n=%d mean=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms",
            samples.count, mean, quantile(0.5), quantile(0.95), quantile(0.99), samples.last ?? 0
        ))
        // Generous budgets (measured mean ~13ms, p95 ~28ms on Apple silicon; baseline was 58ms/112ms) so only real regressions trip them.
        #expect(mean < 40, "mean latency \(mean)ms")
        #expect(quantile(0.95) < 90, "p95 latency \(quantile(0.95))ms")
    }
}
