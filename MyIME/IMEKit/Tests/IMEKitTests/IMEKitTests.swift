import Foundation
import Testing
@testable import IMEKit

private struct MemoryStore: CandidateLookup {
    let entries: [StoreEntry]

    func lookup(pinyinKey: String, initials: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry] {
        entries.filter {
            $0.pinyin.replacingOccurrences(of: "'", with: "").hasPrefix(pinyinKey)
                || $0.pinyin.split(separator: "'").compactMap(\.first).map(String.init).joined() == initials
        }
    }

    func userBoost(word: String, pinyin: String) -> Double { 0 }
    func bigramBoost(previous: String?, word: String) -> Double { 0 }
}

private let store = MemoryStore(entries: [
    StoreEntry(id: 1, word: "你好", pinyin: "ni'hao", weight: 65_535),
    StoreEntry(id: 2, word: "世界", pinyin: "shi'jie", weight: 65_535),
    StoreEntry(id: 3, word: "北京", pinyin: "bei'jing", weight: 65_535),
    StoreEntry(id: 4, word: "中国", pinyin: "zhong'guo", weight: 65_535),
    StoreEntry(id: 5, word: "我爱你", pinyin: "wo'ai'ni", weight: 65_535),
    StoreEntry(id: 6, word: "我", pinyin: "wo", weight: 65_535),
    StoreEntry(id: 7, word: "是", pinyin: "shi", weight: 65_535),
    StoreEntry(id: 8, word: "人", pinyin: "ren", weight: 65_535),
    StoreEntry(id: 9, word: "今天", pinyin: "jin'tian", weight: 65_535),
    StoreEntry(id: 10, word: "天气", pinyin: "tian'qi", weight: 65_535),
    StoreEntry(id: 11, word: "很好", pinyin: "hen'hao", weight: 65_535),
    StoreEntry(id: 12, word: "田七", pinyin: "tian'qi", weight: 45_000),
    StoreEntry(id: 13, word: "医院", pinyin: "yi'yuan", weight: 65_535),
])

private struct ContextStore: CandidateLookup {
    let entries: [StoreEntry]

    func lookup(pinyinKey: String, initials: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry] {
        entries.filter {
            $0.pinyin.replacingOccurrences(of: "'", with: "").hasPrefix(pinyinKey)
                || $0.pinyin.split(separator: "'").compactMap(\.first).map(String.init).joined() == initials
        }
    }

    func userBoost(word: String, pinyin: String) -> Double { 0 }
    func bigramBoost(previous: String?, word: String) -> Double {
        previous == "今天" && word == "天气" ? 10 : 0
    }
}

private struct PredictingStore: CandidateLookup {
    let entries: [StoreEntry]
    let predictions: [String: [StoreEntry]]

    func lookup(pinyinKey: String, initials: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry] {
        entries.filter {
            $0.pinyin.replacingOccurrences(of: "'", with: "").hasPrefix(pinyinKey)
                || $0.pinyin.split(separator: "'").compactMap(\.first).map(String.init).joined() == initials
        }
    }

    func userBoost(word: String, pinyin: String) -> Double { 0 }
    func bigramBoost(previous: String?, word: String) -> Double {
        previous == "今天" && word == "天气" ? 1 : 0
    }
    func predictNext(after previous: String, limit: Int) -> [StoreEntry] {
        Array((predictions[previous] ?? []).prefix(limit))
    }
}

@Suite("Engine") struct EngineTests {
    @Test func traditionalConversionPrefersWholePhrases() {
        let converter = TraditionalConverter(mappings: [
            "头发": "頭髮",
            "发": "發",
            "后": "後",
            "后台": "後臺",
            "开": "開",
        ])
        #expect(converter.convert("头发后台开发") == "頭髮後臺開發")
        #expect(converter.convert("MyIME 123") == "MyIME 123")
    }

    @Test(arguments: [("nihao", "你好"), ("shijie", "世界"), ("beijing", "北京"), ("zhongguo", "中国"), ("woaini", "我爱你")])
    func golden(input: String, expected: String) {
        let output = Engine(store: store).update(input, prefs: EnginePrefs())
        #expect(output.candidates.first?.word == expected)
    }

    @Test func deterministic() {
        let engine = Engine(store: store)
        let expected = engine.update("bj", prefs: EnginePrefs()).candidates.map(\.word)
        for _ in 0..<100 {
            #expect(engine.update("bj", prefs: EnginePrefs()).candidates.map(\.word) == expected)
        }
    }

    @Test func emojiFollowsItsTextCandidate() throws {
        let candidates = Engine(store: store).update("yiyuan", prefs: EnginePrefs()).candidates
        let hospital = try #require(candidates.firstIndex { $0.word == "医院" })
        let emoji = try #require(candidates.firstIndex { $0.word == "🏥" })
        #expect(emoji == hospital + 1)
        #expect(candidates.first?.word == "医院")
    }

    @Test func composesShortSentenceFromDictionaryPieces() {
        let output = Engine(store: store).update("woshizhongguoren", prefs: EnginePrefs())
        #expect(output.candidates.first?.word == "我是中国人")
        #expect(output.candidates.first?.consumedLength == "woshizhongguoren".count)
    }

    @Test func completePhraseOutranksFrequentPartialCandidate() {
        let phraseStore = MemoryStore(entries: [
            StoreEntry(id: 40, word: "爱", pinyin: "ai", weight: 65_535),
            StoreEntry(id: 41, word: "爱死你了", pinyin: "ai'si'ni'le", weight: 41_247),
        ])
        let output = Engine(store: phraseStore).update("aisinile", prefs: EnginePrefs())
        #expect(output.candidates.first?.word == "爱死你了")
    }

    @Test func offersMultipleFullSentenceCandidates() {
        let output = Engine(store: store).update("jintiantianqihenhao", prefs: EnginePrefs())
        #expect(output.candidates.prefix(2).map(\.word) == ["今天天气很好", "今天田七很好"])
        #expect(output.candidates.prefix(2).allSatisfy { $0.consumedLength == "jintiantianqihenhao".count })
    }

    @Test func sentenceCompositionUsesWordContext() {
        let contextStore = ContextStore(entries: [
            StoreEntry(id: 30, word: "今天", pinyin: "jin'tian", weight: 65_535),
            StoreEntry(id: 31, word: "天气", pinyin: "tian'qi", weight: 35_000),
            StoreEntry(id: 32, word: "田七", pinyin: "tian'qi", weight: 65_535),
            StoreEntry(id: 33, word: "很好", pinyin: "hen'hao", weight: 65_535),
        ])
        let output = Engine(store: contextStore).update("jintiantianqihenhao", prefs: EnginePrefs())
        #expect(output.candidates.first?.word == "今天天气很好")
    }

    @Test func suggestionsFollowCommittedWord() {
        let predictingStore = PredictingStore(
            entries: [
                StoreEntry(id: 50, word: "今天", pinyin: "jin'tian", weight: 65_535),
                StoreEntry(id: 51, word: "天气", pinyin: "tian'qi", weight: 65_535),
            ],
            predictions: ["今天": [StoreEntry(id: 52, word: "天气", pinyin: "", weight: 60_000)]]
        )
        let engine = Engine(store: predictingStore)
        engine.commitLearning(word: "今天", pinyin: ["jin", "tian"])
        #expect(engine.suggestions(limit: 5).map(\.word) == ["天气"])
    }

    @Test func invalidInputNeverCrashes() {
        let engine = Engine(store: store)
        for input in ["", "''''", "123", String(repeating: "x", count: 64), "NǐHǎo😀"] {
            _ = engine.update(input, prefs: EnginePrefs())
        }
    }

    @Test func repeatedUserPhraseGainsWeightAndIsRecalled() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MyIME-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let userStore = try #require(UserStore(path: directory.appending(path: "user.sqlite").path))
        var weights: [Int] = []
        for _ in 0..<16 {
            userStore.learnPhrase(word: "新词", pinyin: "xin'ci")
            userStore.waitForPendingWrites()
            weights.append(try #require(userStore.lookup(pinyinKey: "xinci", initials: "xc", limit: 10).first).weight)
        }
        #expect(weights == weights.sorted())
        #expect(weights.last == 65_535)
        let competingStore = MemoryStore(entries: [StoreEntry(id: 20, word: "心词", pinyin: "xin'ci", weight: 65_535)])
        let output = Engine(store: competingStore, userStore: userStore).update("xinci", prefs: EnginePrefs())
        #expect(output.candidates.first?.word == "新词")
    }

    @Test func repeatedWordPairGainsContextWeight() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MyIME-context-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let userStore = try #require(UserStore(path: directory.appending(path: "user.sqlite").path))
        userStore.learn(word: "天气", pinyin: "tian'qi", previous: "今天")
        userStore.waitForPendingWrites()
        let firstBoost = userStore.bigram(previous: "今天", word: "天气")
        for _ in 0..<8 {
            userStore.learn(word: "天气", pinyin: "tian'qi", previous: "今天")
        }
        userStore.waitForPendingWrites()
        #expect(firstBoost > 0)
        #expect(userStore.bigram(previous: "今天", word: "天气") > firstBoost)
    }

    @Test func nearbySeparateSelectionsBecomeARecentPhrase() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MyIME-nearby-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let userStore = try #require(UserStore(path: directory.appending(path: "user.sqlite").path))
        let engine = Engine(store: MemoryStore(entries: []), userStore: userStore)

        engine.commitUserPhrase(word: "输", pinyin: ["shu"], at: 100)
        engine.commitUserPhrase(word: "入", pinyin: ["ru"], at: 102)

        let output = engine.update("shuru", prefs: EnginePrefs())
        #expect(output.candidates.first?.word == "输入")
    }

    @Test func distantSelectionsDoNotBecomeAPhrase() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MyIME-distant-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let userStore = try #require(UserStore(path: directory.appending(path: "user.sqlite").path))
        let engine = Engine(store: MemoryStore(entries: []), userStore: userStore)

        engine.commitUserPhrase(word: "输", pinyin: ["shu"], at: 100)
        engine.commitUserPhrase(word: "入", pinyin: ["ru"], at: 104)

        #expect(engine.update("shuru", prefs: EnginePrefs()).candidates.isEmpty)
    }

    @Test func updateP95StaysWithinBudget() {
        let engine = Engine(store: store)
        var milliseconds: [Double] = []
        for _ in 0..<500 {
            let start = Date.timeIntervalSinceReferenceDate
            _ = engine.update("woaini", prefs: EnginePrefs())
            milliseconds.append((Date.timeIntervalSinceReferenceDate - start) * 1_000)
        }
        milliseconds.sort()
        let p95 = milliseconds[Int(Double(milliseconds.count - 1) * 0.95)]
        #expect(p95 < 20)
    }

    @Test func bundledDictionaryBuildsCommonSentences() throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let databasePath = ProcessInfo.processInfo.environment["MYIME_TEST_SYSTEM_DATABASE"]
            ?? packageDirectory.appending(path: "../MyIME/Resources/system.sqlite").standardizedFileURL.path
        let bundledStore = try #require(SQLiteStore(path: databasePath))
        #expect(bundledStore.traditionalConverter.isAvailable)
        #expect(bundledStore.traditionalConverter.convert("头发后台开发") == "頭髮後臺開發")
        let engine = Engine(store: bundledStore)
        let weather = engine.update("jintiantianqihenhao", prefs: EnginePrefs())
        let dinner = engine.update("womenmingtianyiqichifan", prefs: EnginePrefs())
        let colloquial = engine.update("aisinile", prefs: EnginePrefs())
        let pig = engine.update("xiaozhuzaishuiliyouyong", prefs: EnginePrefs())
        let dog = engine.update("xiaogouzhuihudie", prefs: EnginePrefs())
        let meal = engine.update("jinwanchigefan", prefs: EnginePrefs())
        #expect(weather.candidates.first?.word == "今天天气很好")
        #expect(dinner.candidates.first?.word == "我们明天一起吃饭")
        #expect(colloquial.candidates.first?.word == "爱死你了")
        #expect(pig.candidates.first?.word == "小猪在水里游泳")
        #expect(dog.candidates.first?.word == "小狗追蝴蝶")
        #expect(meal.candidates.first?.word == "今晚吃个饭")

        var milliseconds: [Double] = []
        for _ in 0..<100 {
            let start = Date.timeIntervalSinceReferenceDate
            _ = engine.update("jintiantianqihenhao", prefs: EnginePrefs())
            milliseconds.append((Date.timeIntervalSinceReferenceDate - start) * 1_000)
        }
        milliseconds.sort()
        #expect(milliseconds[94] < 60)
    }
}

@Suite("Segmenter") struct SegmenterTests {
    @Test func fullPinyin() { #expect(Segmenter().segment("nihao").first?.syllables == ["ni", "hao"]) }
    @Test func abbreviation() { #expect(Segmenter().segment("bj").contains { $0.syllables == ["b", "j"] }) }
    @Test func mixedPinyin() { #expect(Segmenter().segment("beij").contains { $0.syllables == ["bei", "j"] }) }
    @Test func hardBoundary() {
        let paths = Segmenter().segment("xi'an")
        #expect(paths.first?.syllables == ["xi", "an"])
    }
    @Test func incompleteTail() { #expect(Segmenter().segment("nihaov").first?.consumedLength == 5) }
}
