import Foundation

struct EmojiProvider: Sendable {
    static let shared = EmojiProvider()

    private let emojisByWord: [String: [String]]

    init() {
        guard let url = Bundle.module.url(forResource: "emoji-map", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            emojisByWord = [:]
            return
        }

        var result: [String: [String]] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count > 1, !fields[0].hasPrefix("#") else { continue }
            let emoji = fields[0]
            for word in fields.dropFirst() where !result[word, default: []].contains(emoji) {
                result[word, default: []].append(emoji)
            }
        }
        emojisByWord = result
    }

    func addingEmojiCandidates(to candidates: [Candidate], limit: Int) -> [Candidate] {
        var result: [Candidate] = []
        var usedEmoji = Set<String>()
        result.reserveCapacity(min(limit, candidates.count * 2))

        for candidate in candidates {
            guard result.count < limit else { break }
            result.append(candidate)
            for emoji in emojisByWord[candidate.word] ?? [] where result.count < limit && usedEmoji.insert(emoji).inserted {
                result.append(Candidate(
                    id: stableID(for: emoji),
                    word: emoji,
                    pinyinPath: candidate.pinyinPath,
                    score: candidate.score.nextDown,
                    consumedLength: candidate.consumedLength
                ))
            }
        }
        return result
    }

    private func stableID(for value: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(bitPattern: hash | (1 << 63))
    }
}
