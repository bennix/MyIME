import Foundation

public final class Engine: IMEEngine, @unchecked Sendable {
    private let store: any CandidateLookup
    private let userStore: UserStore?
    private let segmenter: Segmenter
    private let stateLock = NSLock()
    private var previousCommitted: String?
    private var recentPhrase: (word: String, pinyin: [String], timestamp: TimeInterval)?

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

        let previous = stateLock.withLock { previousCommitted }
        let inputLength = max(1, normalized.filter { $0 != "'" }.count)
        var best: [String: Candidate] = [:]
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        for path in paths {
            if ContinuousClock.now >= deadline { break }
            let pinyinKey = path.syllables.joined()
            let initials = path.syllables.compactMap(\.first).map(String.init).joined()
            var matches = (store.lookup(pinyinKey: pinyinKey, initials: initials, disabledSourceMask: prefs.disabledSourceMask, limit: 100)
                + (userStore?.lookup(pinyinKey: pinyinKey, initials: initials, limit: 100) ?? []))
                .map { ($0, path.consumedLength, 0) }
            if path.syllables.count > 1, let first = path.syllables.first {
                let fallback = (store.lookup(pinyinKey: first, initials: String(first.prefix(1)), disabledSourceMask: prefs.disabledSourceMask, limit: 30)
                    + (userStore?.lookup(pinyinKey: first, initials: String(first.prefix(1)), limit: 30) ?? []))
                    .filter { $0.pinyin.split(separator: "'").count == 1 }
                    .map { ($0, first.count, 1) }
                matches += fallback
            }
            for (entry, consumedLength, fallbackPenalty) in matches {
                let pinyin = entry.pinyin.split(separator: "'").map(String.init)
                let frequency = Double(entry.weight) / 65_535.0
                let learnedPhraseBoost = entry.id < 0 ? frequency : 0
                let user = learnedPhraseBoost + (userStore?.boost(word: entry.word, pinyin: entry.pinyin) ?? 0) + store.userBoost(word: entry.word, pinyin: entry.pinyin)
                let context = (userStore?.bigram(previous: previous, word: entry.word) ?? 0)
                    + store.bigramBoost(previous: previous, word: entry.word) * 4.0
                let unigram = store.unigramBoost(word: entry.word)
                let incompleteRatio = 1 - Double(consumedLength) / Double(inputLength)
                let score = prefs.frequencyWeight * frequency
                    + prefs.userWeight * user
                    + prefs.lengthWeight * min(Double(entry.word.count), 6) / 6.0
                    + prefs.contextWeight * context
                    + 0.28 * unigram
                    - prefs.fuzzyPenalty * Double(path.fuzzyMatches)
                    - prefs.partialPenalty * Double(path.partialCount + fallbackPenalty)
                    - 0.45 * max(0, incompleteRatio)
                let candidate = Candidate(id: entry.id, word: entry.word, pinyinPath: pinyin, score: score, consumedLength: consumedLength)
                let key = entry.word + "\u{0}" + entry.pinyin
                if best[key].map({ candidate.score > $0.score }) ?? true { best[key] = candidate }
            }
        }
        let sentences = paths.prefix(2)
            .flatMap { sentenceCandidates(for: $0, previous: previous, prefs: prefs, limit: 6) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.word < $1.word
            }
        let topScore = best.values.map(\.score).max() ?? 0
        var seenSentences = Set<String>()
        for (index, sentence) in sentences.filter({ seenSentences.insert($0.word).inserted }).prefix(6).enumerated() {
            let key = sentence.word + "\u{0}" + sentence.pinyinPath.joined(separator: "'")
            guard best[key] == nil else { continue }
            best[key] = Candidate(
                id: sentence.id,
                word: sentence.word,
                pinyinPath: sentence.pinyinPath,
                score: topScore + Double(sentences.count - index) + sentence.score * 0.01,
                consumedLength: sentence.consumedLength
            )
        }
        let candidates = best.values.sorted {
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

    public func suggestions(limit: Int = 9) -> [Candidate] {
        let previous = stateLock.withLock { previousCommitted }
        guard let previous, !previous.isEmpty else { return [] }
        var anchors = [previous]
        if previous.count > 2 { anchors.append(String(previous.suffix(2))) }
        if previous.count > 1 { anchors.append(String(previous.suffix(1))) }

        var seen = Set<String>()
        var ranked: [(word: String, score: Double)] = []
        for anchor in anchors {
            for entry in store.predictNext(after: anchor, limit: limit * 3) {
                // Association chips should be usable words, not function-word residue from corpora.
                guard entry.word.count >= 2, seen.insert(entry.word).inserted else { continue }
                let score = Double(entry.weight) / 65_535.0
                    + store.bigramBoost(previous: anchor, word: entry.word) * 2.0
                    + store.unigramBoost(word: entry.word) * 0.55
                ranked.append((entry.word, score))
            }
            if ranked.count >= limit { break }
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

    private struct SentenceHypothesis {
        let word: String
        let score: Double
        let pieces: Int
        let lastWord: String?
    }

    private func sentenceCandidates(for path: SegmentationPath, previous: String?, prefs: EnginePrefs, limit: Int) -> [Candidate] {
        guard path.syllables.count > 1, path.syllables.count <= 14, path.partialCount == 0 else { return [] }
        let fullKey = path.syllables.joined()
        let hasExactPhrase = !(store.lookupExact(
            pinyinKey: fullKey,
            disabledSourceMask: prefs.disabledSourceMask,
            limit: 1
        ) + (userStore?.lookupExact(pinyinKey: fullKey, limit: 1) ?? [])).isEmpty
        guard !hasExactPhrase else { return [] }

        var beams = Array(repeating: [SentenceHypothesis](), count: path.syllables.count + 1)
        beams[0] = [SentenceHypothesis(word: "", score: 0, pieces: 0, lastWord: nil)]
        for cursor in path.syllables.indices where !beams[cursor].isEmpty {
            let maxEnd = min(path.syllables.count, cursor + 6)
            for end in (cursor + 1)...maxEnd {
                let syllables = Array(path.syllables[cursor..<end])
                let key = syllables.joined()
                let entries = (store.lookupExact(pinyinKey: key, disabledSourceMask: prefs.disabledSourceMask, limit: 30)
                    + (userStore?.lookupExact(pinyinKey: key, limit: 30) ?? []))
                    .sorted {
                        if $0.weight != $1.weight { return $0.weight > $1.weight }
                        if $0.word != $1.word { return $0.word < $1.word }
                        return $0.id < $1.id
                    }
                    .prefix(10)
                for hypothesis in beams[cursor] {
                    for entry in entries {
                        let frequency = Double(entry.weight) / 65_535.0
                        let user = (userStore?.boost(word: entry.word, pinyin: entry.pinyin) ?? 0)
                            + store.userBoost(word: entry.word, pinyin: entry.pinyin)
                        let contextPrevious = hypothesis.lastWord ?? previous
                        let context = (userStore?.bigram(previous: contextPrevious, word: entry.word) ?? 0)
                            + store.bigramBoost(previous: contextPrevious, word: entry.word) * 5.0
                        let unigram = store.unigramBoost(word: entry.word)
                        let sequence = store.sequenceBoost(prefix: hypothesis.word, word: entry.word)
                        let syllableSpan = Double(end - cursor)
                        // Prefer multi-syllable dictionary hits over high-frequency single characters.
                        let multiSyllableBonus = syllableSpan > 1 ? 0.65 * (syllableSpan - 1) : 0
                        let unigramWeight = syllableSpan > 1 ? 0.45 : 0.18
                        let score = hypothesis.score
                            + frequency * syllableSpan
                            + prefs.userWeight * user
                            + prefs.contextWeight * context
                            + unigramWeight * unigram * syllableSpan
                            + 0.35 * sequence
                            + multiSyllableBonus
                            - 0.55
                        beams[end].append(SentenceHypothesis(
                            word: hypothesis.word + entry.word,
                            score: score,
                            pieces: hypothesis.pieces + 1,
                            lastWord: entry.word
                        ))
                    }
                }
                beams[end].sort {
                    if $0.score != $1.score { return $0.score > $1.score }
                    if $0.pieces != $1.pieces { return $0.pieces < $1.pieces }
                    return $0.word < $1.word
                }
                if beams[end].count > 10 { beams[end].removeSubrange(10...) }
            }
        }
        var seen = Set<String>()
        return beams[path.syllables.count]
            .filter { $0.pieces > 1 && seen.insert($0.word).inserted }
            .prefix(limit)
            .enumerated()
            .map { index, hypothesis in
                Candidate(
                    id: Int64.min + Int64(index),
                    word: hypothesis.word,
                    pinyinPath: path.syllables,
                    score: hypothesis.score,
                    consumedLength: path.consumedLength
                )
            }
    }

    public func select(_ index: Int, from output: EngineOutput) -> SelectResult {
        guard output.candidates.indices.contains(index) else { return SelectResult(commitText: "", remainingRaw: output.raw) }
        let candidate = output.candidates[index]
        let plainRaw = output.raw.filter { $0 != "'" }
        let remaining = String(plainRaw.dropFirst(min(candidate.consumedLength, plainRaw.count)))
        return SelectResult(commitText: candidate.word, remainingRaw: remaining)
    }

    public func commitLearning(word: String, pinyin: [String]) {
        let previous = stateLock.withLock { () -> String? in
            defer { previousCommitted = word }
            return previousCommitted
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
