import Foundation

public final class Engine: IMEEngine, @unchecked Sendable {
    private let store: any CandidateLookup
    private let userStore: UserStore?
    private let segmenter: Segmenter
    private let stateLock = NSLock()
    private var committedHistory: (last: String?, beforeLast: String?) = (nil, nil)
    private var recentPhrase: (word: String, pinyin: [String], timestamp: TimeInterval)?

    /// Log-domain scoring scale. `wordLogProb` maps a blended 0..1 frequency onto a
    /// pseudo ln-count axis so single words and multi-word sentence compositions
    /// score on the same, comparable scale: every extra word costs `wordPenalty`
    /// (≈ -ln P of a top-frequency word) unless a strong bigram/trigram pays it back.
    private enum Scale {
        static let logRange = 16.0        // dynamic range of the pseudo log-probability
        static let wordPenalty = 3.2      // per-word insertion cost
        static let bigramReward = 6.0     // system word-bigram transition reward
        static let userBigramReward = 1.4 // user bigram reward (log1p count, 0..4)
        static let trigramReward = 1.6    // char-trigram boundary reward
        static let userReward = 8.0       // user frequency/recency reward
        static let fuzzyPenalty = 2.2     // per fuzzy syllable substitution
        static let typoPenalty = 4.5      // per corrected transposition typo
        static let partialPenalty = 1.1   // per abbreviated (initial-only) syllable
        static let prefixPenalty = 0.8    // speculative pinyin-prefix completion
        static let completionPenalty = 0.8 // per syllable the completion adds beyond typed tail
        static let incompletePenalty = 5.0 // scaled by unconsumed input ratio
    }

    public init(store: any CandidateLookup, userStore: UserStore? = nil, segmenter: Segmenter = Segmenter()) {
        self.store = store
        self.userStore = userStore
        self.segmenter = segmenter
    }

    public func update(_ raw: String, prefs: EnginePrefs) -> EngineOutput {
        let normalized = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0 == "'") }
        guard !normalized.isEmpty else { return EngineOutput(preedit: "", candidates: [], hasMore: false, raw: "") }
        let paths = segmenter.segment(normalized, fuzzy: prefs.fuzzy, limit: 4)
        guard let firstPath = paths.first else {
            return EngineOutput(preedit: normalized, candidates: [], hasMore: false, raw: normalized)
        }

        let history = stateLock.withLock { committedHistory }
        let anchors = contextAnchors(last: history.last, beforeLast: history.beforeLast)
        let inputLength = max(1, normalized.filter { $0 != "'" }.count)
        let userScale = prefs.userWeight / 0.35
        let fuzzyScale = prefs.fuzzyPenalty / 0.08
        let partialScale = prefs.partialPenalty / 0.1
        var best: [String: Candidate] = [:]
        let wordDeadline = ContinuousClock.now.advanced(by: .milliseconds(40))
        for path in paths {
            if ContinuousClock.now >= wordDeadline { break }
            let pinyinKey = path.syllables.joined()
            // Initials matching is only meaningful when every typed letter stands for
            // one syllable (pure abbreviation). Full-pinyin input must not recall
            // abbreviation homonyms (e.g. "xiexie" → initials "xx" → 学习).
            let isAbbreviation = path.syllables.allSatisfy { $0.count == 1 }
            let initials = isAbbreviation ? path.syllables.joined() : ""
            var matches = (store.lookup(pinyinKey: pinyinKey, initials: initials, disabledSourceMask: prefs.disabledSourceMask, limit: 100)
                + (userStore?.lookup(pinyinKey: pinyinKey, initials: initials, limit: 100) ?? []))
                .map { ($0, path.consumedLength, 0) }
            if path.syllables.count > 1, let first = path.syllables.first {
                let firstInitials = first.count == 1 ? first : ""
                let fallback = (store.lookup(pinyinKey: first, initials: firstInitials, disabledSourceMask: prefs.disabledSourceMask, limit: 30)
                    + (userStore?.lookup(pinyinKey: first, initials: firstInitials, limit: 30) ?? []))
                    .filter { $0.pinyin.split(separator: "'").count == 1 }
                    .map { ($0, first.count, 1) }
                matches += fallback
            }
            let pathPenalty = Scale.fuzzyPenalty * fuzzyScale * Double(path.fuzzyMatches)
                + Scale.typoPenalty * Double(path.typoCount)
                + Scale.partialPenalty * partialScale * Double(path.partialCount)
            for (entry, consumedLength, fallbackPenalty) in matches {
                let pinyin = entry.pinyin.split(separator: "'").map(String.init)
                let entryKey = entry.pinyin.replacingOccurrences(of: "'", with: "")
                let base = wordLogProb(word: entry.word, weight: entry.weight, isUserEntry: entry.id < 0) - Scale.wordPenalty
                let user = (userStore?.boost(word: entry.word, pinyin: entry.pinyin) ?? 0) + store.userBoost(word: entry.word, pinyin: entry.pinyin)
                let context = contextBonus(anchors: anchors, word: entry.word)
                let prefixCompletion = entryKey != pinyinKey && entryKey.hasPrefix(pinyinKey) ? Scale.prefixPenalty : 0
                let incompleteRatio = 1 - Double(consumedLength) / Double(inputLength)
                let score = prefs.frequencyWeight * base
                    + Scale.userReward * userScale * user
                    + (prefs.contextWeight / 0.2) * context
                    - pathPenalty
                    - Scale.wordPenalty * Double(fallbackPenalty)
                    - prefixCompletion
                    - Scale.incompletePenalty * max(0, incompleteRatio)
                let candidate = Candidate(id: entry.id, word: entry.word, pinyinPath: pinyin, score: score, consumedLength: consumedLength)
                // Key on the separator-free pinyin so identical readings collapse across paths.
                let key = entry.word + "\u{0}" + entryKey
                if best[key].map({ candidate.score > $0.score }) ?? true { best[key] = candidate }
            }
        }
        // The lattice gets its own budget from this point so a slow cold word lookup
        // can never starve sentence composition; the first path always completes.
        let latticeStart = ContinuousClock.now
        let latticeDeadline = latticeStart.advanced(by: .milliseconds(60))
        for (pathIndex, path) in paths.prefix(2).enumerated() {
            if pathIndex > 0, ContinuousClock.now >= latticeDeadline { break }
            let pathDeadline = pathIndex == 0 ? latticeStart.advanced(by: .milliseconds(150)) : latticeDeadline
            for sentence in latticeCandidates(for: path, anchors: anchors, prefs: prefs, deadline: pathDeadline, limit: 6) {
                let key = sentence.word + "\u{0}" + sentence.pinyinPath.joined()
                if best[key].map({ sentence.score > $0.score }) ?? true { best[key] = sentence }
            }
        }
        let candidates = best.values.sorted {
            let lhsFull = $0.consumedLength >= inputLength
            let rhsFull = $1.consumedLength >= inputLength
            if lhsFull != rhsFull { return lhsFull }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.word != $1.word { return $0.word < $1.word }
            return $0.id < $1.id
        }
        let candidatesWithEmoji = EmojiProvider.shared.addingEmojiCandidates(to: candidates, limit: 100)
        return EngineOutput(
            preedit: firstPath.preedit,
            candidates: candidatesWithEmoji,
            hasMore: candidates.count > 100,
            raw: normalized
        )
    }

    // MARK: - Log-domain scoring

    /// Blend dictionary weight with the corpus unigram model. Entries the corpus has
    /// never seen (merged sources inflate proper nouns like 江泽民同志) are strongly
    /// discounted so they cannot outrank corpus-supported words.
    private func frequencyBlend(word: String, weight: Int, isUserEntry: Bool) -> Double {
        let dictionary = Double(weight) / 65_535.0
        if isUserEntry { return dictionary }
        let unigram = store.unigramBoost(word: word)
        if unigram > 0 { return min(1, 0.55 * unigram + 0.45 * dictionary) }
        return (word.count == 1 ? 0.4 : 0.32) * dictionary
    }

    private func wordLogProb(word: String, weight: Int, isUserEntry: Bool) -> Double {
        Scale.logRange * (frequencyBlend(word: word, weight: weight, isUserEntry: isUserEntry) - 1)
    }

    /// Anchor chain for cross-commit context: the last committed word, the last two
    /// committed words joined (catches word pairs committed separately), and the
    /// 2-character suffix of a long committed phrase.
    private func contextAnchors(last: String?, beforeLast: String?) -> [String] {
        guard let last, !last.isEmpty else { return [] }
        var anchors = [last]
        if let beforeLast, !beforeLast.isEmpty, beforeLast.count + last.count <= 4 {
            anchors.append(beforeLast + last)
        }
        if last.count > 2 { anchors.append(String(last.suffix(2))) }
        return anchors
    }

    private func contextBonus(anchors: [String], word: String) -> Double {
        guard !anchors.isEmpty else { return 0 }
        var bonus = 0.0
        for (index, anchor) in anchors.enumerated() {
            let scale = index == 0 ? 1.0 : 0.6
            let system = store.bigramBoost(previous: anchor, word: word) * Scale.bigramReward * 0.6
            let user = (userStore?.bigram(previous: anchor, word: word) ?? 0) * Scale.userBigramReward
            bonus = max(bonus, scale * (system + user))
        }
        if let first = anchors.first {
            bonus += store.sequenceBoost(prefix: first, word: word) * Scale.trigramReward * 0.5
        }
        return bonus
    }

    /// In-sentence transition reward: pays back part of the per-word insertion cost
    /// when the word-bigram / char-trigram evidence supports the junction.
    private func transitionBonus(previousWord: String, word: String) -> Double {
        let system = store.bigramBoost(previous: previousWord, word: word) * Scale.bigramReward
        let user = (userStore?.bigram(previous: previousWord, word: word) ?? 0) * Scale.userBigramReward
        let sequence = store.sequenceBoost(prefix: previousWord, word: word) * Scale.trigramReward
        return system + user + sequence
    }

    // MARK: - Sentence lattice (Viterbi beam)

    private struct Hypothesis {
        let text: String
        let score: Double
        let pieces: Int
        let lastWord: String
    }

    private static func hypothesisPrecedes(_ lhs: Hypothesis, _ rhs: Hypothesis) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.pieces != rhs.pieces { return lhs.pieces < rhs.pieces }
        return lhs.text < rhs.text
    }

    /// Composes sentence candidates over the word lattice with a beam search that
    /// maximizes the summed log-domain score. Runs on every multi-syllable input;
    /// a trailing abbreviated segment is completed through prefix lookup so the
    /// sentence keeps forming while the user is still typing.
    private func latticeCandidates(
        for path: SegmentationPath,
        anchors: [String],
        prefs: EnginePrefs,
        deadline: ContinuousClock.Instant,
        limit: Int
    ) -> [Candidate] {
        let syllables = path.syllables
        guard syllables.count > 1, syllables.count <= 16 else { return [] }
        let isPartialSyllable: (String) -> Bool = { $0.count == 1 && !"aoe".contains($0) }
        let firstPartial = syllables.firstIndex(where: isPartialSyllable) ?? syllables.count
        guard firstPartial >= 2 else { return [] }

        let userScale = prefs.userWeight / 0.35
        let fuzzyScale = prefs.fuzzyPenalty / 0.08
        let partialScale = prefs.partialPenalty / 0.1
        let beamWidth = 12

        func nodeScore(_ entry: StoreEntry) -> Double {
            let user = (userStore?.boost(word: entry.word, pinyin: entry.pinyin) ?? 0)
                + store.userBoost(word: entry.word, pinyin: entry.pinyin)
            return wordLogProb(word: entry.word, weight: entry.weight, isUserEntry: entry.id < 0)
                - Scale.wordPenalty
                + Scale.userReward * userScale * user
        }
        func linkScore(from hypothesis: Hypothesis, to word: String) -> Double {
            guard hypothesis.pieces > 0 else {
                return contextBonus(anchors: anchors, word: word) * 0.8
            }
            return transitionBonus(previousWord: hypothesis.lastWord, word: word)
        }
        func extend(_ beam: inout [Hypothesis], from sources: [Hypothesis], entries: some Collection<StoreEntry>, extra: Double = 0) {
            let scored = entries.map { ($0, nodeScore($0)) }
            for hypothesis in sources {
                for (entry, node) in scored {
                    beam.append(Hypothesis(
                        text: hypothesis.text + entry.word,
                        score: hypothesis.score + node + linkScore(from: hypothesis, to: entry.word) + extra,
                        pieces: hypothesis.pieces + 1,
                        lastWord: entry.word
                    ))
                }
            }
            if beam.count > beamWidth {
                beam.sort(by: Self.hypothesisPrecedes)
                beam.removeSubrange(beamWidth...)
            }
        }

        var beams = Array(repeating: [Hypothesis](), count: firstPartial + 1)
        beams[0] = [Hypothesis(text: "", score: 0, pieces: 0, lastWord: "")]
        for cursor in 0..<firstPartial where !beams[cursor].isEmpty {
            if ContinuousClock.now >= deadline { break }
            let maxEnd = min(firstPartial, cursor + 6)
            for end in (cursor + 1)...maxEnd {
                let key = syllables[cursor..<end].joined()
                let entries = (store.lookupExact(pinyinKey: key, disabledSourceMask: prefs.disabledSourceMask, limit: 30)
                    + (userStore?.lookupExact(pinyinKey: key, limit: 10) ?? []))
                    .sorted {
                        if $0.weight != $1.weight { return $0.weight > $1.weight }
                        if $0.word != $1.word { return $0.word < $1.word }
                        return $0.id < $1.id
                    }
                    .prefix(10)
                guard !entries.isEmpty else { continue }
                extend(&beams[end], from: beams[cursor], entries: entries)
            }
        }

        var finals: [Hypothesis] = []
        if firstPartial == syllables.count {
            finals = beams[firstPartial]
        } else if syllables.count - firstPartial <= 6 {
            // Complete the abbreviated tail (e.g. "tianqih" → 天气 + 好/后/…) from any
            // hypothesis whose last word may also swallow preceding full syllables.
            for cursor in max(1, firstPartial - 2)...firstPartial where !beams[cursor].isEmpty {
                if ContinuousClock.now >= deadline { break }
                let tail = syllables[cursor...]
                guard tail.count <= 6 else { continue }
                let key = tail.joined()
                let tailInitials = tail.allSatisfy { $0.count == 1 } ? tail.joined() : ""
                let entries = (store.lookup(pinyinKey: key, initials: tailInitials, disabledSourceMask: prefs.disabledSourceMask, limit: 20)
                    + (userStore?.lookup(pinyinKey: key, initials: tailInitials, limit: 10) ?? []))
                    .prefix(10)
                guard !entries.isEmpty else { continue }
                // Prefer completions close to what was typed: 现在很m → 很忙/很美
                // over 很明显/很迷茫 (each speculative extra syllable costs).
                for entry in entries {
                    let entrySyllables = entry.pinyin.isEmpty
                        ? entry.word.count
                        : entry.pinyin.split(separator: "'").count
                    let excess = Double(max(0, entrySyllables - tail.count))
                    extend(
                        &finals,
                        from: beams[cursor],
                        entries: CollectionOfOne(entry),
                        extra: -Scale.prefixPenalty - Scale.completionPenalty * excess
                    )
                }
            }
        }

        let pathPenalty = Scale.fuzzyPenalty * fuzzyScale * Double(path.fuzzyMatches)
            + Scale.typoPenalty * Double(path.typoCount)
            + Scale.partialPenalty * partialScale * Double(path.partialCount)
        var seen = Set<String>()
        return finals
            .sorted(by: Self.hypothesisPrecedes)
            .filter { $0.pieces > 1 && seen.insert($0.text).inserted }
            .prefix(limit)
            .enumerated()
            .map { index, hypothesis in
                Candidate(
                    id: Int64.min + Int64(index),
                    word: hypothesis.text,
                    pinyinPath: syllables,
                    score: hypothesis.score - pathPenalty,
                    consumedLength: path.consumedLength
                )
            }
    }

    // MARK: - Suggestions

    public func suggestions(limit: Int = 9) -> [Candidate] {
        let previous = stateLock.withLock { committedHistory.last }
        guard let previous, !previous.isEmpty else { return [] }

        // Prefer the exact committed phrase. Single-character suffix anchors pull in web junk
        // and drown useful continuations, so only keep a two-character suffix as fallback.
        var anchors = [previous]
        if previous.count > 2 { anchors.append(String(previous.suffix(2))) }

        var seen = Set<String>()
        var ranked: [(word: String, score: Double)] = []
        func consider(word: String, anchor: String, base: Double, exactAnchor: Bool) {
            guard word.count >= 2, !Self.isLowQualityAssociation(word), seen.insert(word).inserted else { return }
            let user = userStore?.bigram(previous: previous, word: word) ?? 0
            let system = store.bigramBoost(previous: anchor, word: word)
            let sequence = store.sequenceBoost(prefix: previous, word: word)
            let unigram = store.unigramBoost(word: word)
            // User intent and exact-phrase bigrams dominate; raw unigram often rewards content-farm heads.
            let score = base
                + user * 2.8
                + system * (exactAnchor ? 3.2 : 1.1)
                + sequence * 0.9
                + unigram * 0.12
            ranked.append((word, score))
        }

        for entry in userStore?.predictNext(after: previous, limit: limit * 2) ?? [] {
            consider(word: entry.word, anchor: previous, base: Double(entry.weight) / 65_535.0 + 1.5, exactAnchor: true)
        }
        for word in AssociationSeeds.continuations(after: previous) {
            consider(word: word, anchor: previous, base: 1.8, exactAnchor: true)
        }
        for (index, anchor) in anchors.enumerated() {
            let exactAnchor = index == 0
            for entry in store.predictNext(after: anchor, limit: limit * 4) {
                consider(
                    word: entry.word,
                    anchor: anchor,
                    base: Double(entry.weight) / 65_535.0 * (exactAnchor ? 0.45 : 0.2),
                    exactAnchor: exactAnchor
                )
            }
            if exactAnchor, ranked.count >= limit { break }
        }

        return ranked
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.word < $1.word
            }
            .prefix(limit)
            .enumerated()
            .map { index, item in
                Candidate(
                    id: Int64.min / 4 + Int64(index),
                    word: item.word,
                    pinyinPath: [],
                    score: item.score,
                    consumedLength: 0
                )
            }
    }

    private static func isLowQualityAssociation(_ word: String) -> Bool {
        let bannedFragments = [
            "小编", "给大家", "为大家", "特价", "大盘", "点击", "点赞", "关注", "转发",
            "头条", "链接", "阅读原文", "扫码", "微信号",
        ]
        return bannedFragments.contains { word.contains($0) }
    }

    // MARK: - Selection & learning

    public func select(_ index: Int, from output: EngineOutput) -> SelectResult {
        guard output.candidates.indices.contains(index) else { return SelectResult(commitText: "", remainingRaw: output.raw) }
        let candidate = output.candidates[index]
        let plainRaw = output.raw.filter { $0 != "'" }
        let remaining = String(plainRaw.dropFirst(min(candidate.consumedLength, plainRaw.count)))
        return SelectResult(commitText: candidate.word, remainingRaw: remaining)
    }

    public func commitLearning(word: String, pinyin: [String]) {
        let previous = stateLock.withLock { () -> String? in
            defer { committedHistory = (last: word, beforeLast: committedHistory.last) }
            return committedHistory.last
        }
        userStore?.learn(word: word, pinyin: pinyin.joined(separator: "'"), previous: previous)
    }

    public func commitUserPhrase(word: String, pinyin: [String], at time: TimeInterval? = nil) {
        guard !word.isEmpty, !pinyin.isEmpty else { return }
        let timestamp = time ?? Date().timeIntervalSinceReferenceDate
        let combined = stateLock.withLock { () -> (String, [String])? in
            guard let recentPhrase,
                  timestamp >= recentPhrase.timestamp,
                  timestamp - recentPhrase.timestamp <= 3 else {
                self.recentPhrase = (word, pinyin, timestamp)
                return nil
            }
            let combinedWord = recentPhrase.word + word
            let combinedPinyin = recentPhrase.pinyin + pinyin
            guard combinedWord.count <= 12, combinedPinyin.count <= 12 else {
                self.recentPhrase = (word, pinyin, timestamp)
                return nil
            }
            self.recentPhrase = (combinedWord, combinedPinyin, timestamp)
            return (combinedWord, combinedPinyin)
        }
        if word.count > 1 {
            userStore?.learnPhrase(word: word, pinyin: pinyin.joined(separator: "'"))
        }
        if let combined {
            userStore?.learnPhrase(word: combined.0, pinyin: combined.1.joined(separator: "'"))
        }
    }

    public func breakPhraseLearningContext() {
        stateLock.withLock { recentPhrase = nil }
    }
}

/// High-frequency, intent-oriented continuations that corpus bigrams often miss
/// (e.g. webtext strongly prefers 今天→小编 over 今天→天气).
enum AssociationSeeds {
    private static let table: [String: [String]] = [
        "今天": ["天气", "早上", "晚上", "中午", "怎么样"],
        "明天": ["天气", "早上", "晚上", "一起", "再见"],
        "昨天": ["晚上", "已经", "发生", "天气"],
        "现在": ["开始", "可以", "时间", "感觉"],
        "因为": ["所以", "这样", "天气", "工作"],
        "所以": ["我们", "今天", "决定", "需要"],
        "可以": ["帮助", "开始", "试试", "理解"],
        "我们": ["一起", "需要", "可以", "今天"],
        "你们": ["好的", "可以", "觉得", "需要"],
        "他们": ["觉得", "已经", "可能", "需要"],
        "这个": ["问题", "方案", "事情", "想法"],
        "那个": ["问题", "时候", "地方", "想法"],
        "真的": ["很好", "喜欢", "不错", "可以"],
        "非常": ["喜欢", "感谢", "重要", "开心"],
        "开始": ["工作", "学习", "输入", "吧"],
        "希望": ["大家", "你能", "明天", "顺利"],
        "觉得": ["不错", "可以", "很好", "应该"],
        "应该": ["可以", "没问题", "注意", "这样"],
        "没有": ["问题", "办法", "关系", "时间"],
        "不是": ["问题", "这样", "很好", "故意"],
    ]

    static func continuations(after previous: String) -> [String] {
        if let exact = table[previous] { return exact }
        if previous.count > 2, let suffix = table[String(previous.suffix(2))] { return suffix }
        return []
    }
}

public enum RuntimePaths {
    public static var userDatabase: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appending(path: "fudan.miniS.MyIME/user.sqlite").path
    }

    public static var replacementSystemDatabase: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appending(path: "fudan.miniS.MyIME/system.sqlite").path
    }
}
