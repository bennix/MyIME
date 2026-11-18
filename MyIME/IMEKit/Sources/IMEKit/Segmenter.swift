import Foundation

public struct SegmentationPath: Equatable, Sendable {
    public let syllables: [String]
    public let consumedLength: Int
    public let fuzzyMatches: Int
    public let partialCount: Int
    public let typoCount: Int

    public init(syllables: [String], consumedLength: Int, fuzzyMatches: Int, partialCount: Int, typoCount: Int = 0) {
        self.syllables = syllables
        self.consumedLength = consumedLength
        self.fuzzyMatches = fuzzyMatches
        self.partialCount = partialCount
        self.typoCount = typoCount
    }

    public var preedit: String { syllables.joined(separator: "'") }
}

public struct Segmenter: Sendable {
    private let syllables: Set<String>
    private let initials = Set("bpmfdtnlgkhjqxzcsryw".map(String.init))
    /// Formal full finals users occasionally type; normalized penalty-free because
    /// the raw spelling is never a valid syllable on its own.
    private static let fullFormFinals = [("uen", "un"), ("uei", "ui"), ("iou", "iu")]

    public init(syllables: Set<String> = PinyinTable.syllables) {
        self.syllables = syllables
    }

    public func segment(_ raw: String, fuzzy: FuzzyRules = FuzzyRules(), limit: Int = 8) -> [SegmentationPath] {
        let normalized = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0 == "'") }
        guard !normalized.isEmpty else { return [] }
        let pieces = normalized.split(separator: "'", omittingEmptySubsequences: false).map(String.init)
        var combined = [SegmentationPath(syllables: [], consumedLength: 0, fuzzyMatches: 0, partialCount: 0)]

        for piece in pieces where !piece.isEmpty {
            let paths = segmentPiece(piece, fuzzy: fuzzy, limit: limit)
            guard !paths.isEmpty else { continue }
            combined = combined.flatMap { prefix in
                paths.map { path in
                    SegmentationPath(
                        syllables: prefix.syllables + path.syllables,
                        consumedLength: prefix.consumedLength + path.consumedLength,
                        fuzzyMatches: prefix.fuzzyMatches + path.fuzzyMatches,
                        partialCount: prefix.partialCount + path.partialCount,
                        typoCount: prefix.typoCount + path.typoCount
                    )
                }
            }
            .sorted(by: Self.precedes)
            .prefix(limit)
            .map { $0 }
        }
        return combined.filter { !$0.syllables.isEmpty }.sorted(by: Self.precedes)
    }

    /// Exact bounded k-best segmentation. Every ranking component (partial, typo, fuzzy,
    /// syllable count) is additive, so prepending a token shifts all suffix parses equally and
    /// the best `limit` parses of a suffix suffice to build the best `limit` of the whole
    /// piece. This replaces an unordered DFS that stopped after `limit * 8` hits, which let
    /// typo-corrected parses (shia→shai) displace complete clean ones.
    private func segmentPiece(_ text: String, fuzzy: FuzzyRules, limit: Int) -> [SegmentationPath] {
        let chars = Array(text)
        guard limit > 0 else { return [] }
        // Suffix parse: syllables from `index` on; `end` is the absolute consumed length.
        typealias Part = (syllables: [String], end: Int, fuzzy: Int, partial: Int, typo: Int)
        var memo: [Int: [Part]] = [:]  // key = index * 2 + (typoAllowed ? 1 : 0)

        func better(_ lhs: Part, _ rhs: Part) -> Bool {
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            if lhs.partial != rhs.partial { return lhs.partial < rhs.partial }
            if lhs.typo != rhs.typo { return lhs.typo < rhs.typo }
            if lhs.fuzzy != rhs.fuzzy { return lhs.fuzzy < rhs.fuzzy }
            if lhs.syllables.count != rhs.syllables.count { return lhs.syllables.count < rhs.syllables.count }
            return lhs.syllables.joined(separator: "'") < rhs.syllables.joined(separator: "'")
        }

        func best(_ index: Int, typoAllowed: Bool) -> [Part] {
            if index == chars.count { return [([], index, 0, 0, 0)] }
            let key = index * 2 + (typoAllowed ? 1 : 0)
            if let cached = memo[key] { return cached }
            var candidates: [Part] = []
            func extend(_ syllable: String, to end: Int, fuzzy fuzzyDelta: Int, partial: Int, typo: Int) {
                for tail in best(end, typoAllowed: typoAllowed && typo == 0) {
                    candidates.append(([syllable] + tail.syllables, tail.end,
                                       tail.fuzzy + fuzzyDelta, tail.partial + partial, tail.typo + typo))
                }
            }
            var found = false
            let maxEnd = min(chars.count, index + 6)
            for end in stride(from: maxEnd, through: index + 1, by: -1) {
                let token = String(chars[index..<end])
                if syllables.contains(token) {
                    found = true
                    extend(token, to: end, fuzzy: 0, partial: 0, typo: 0)
                } else if let normalized = normalizedFullForm(of: token) {
                    found = true
                    extend(normalized, to: end, fuzzy: 0, partial: 0, typo: 0)
                } else if typoAllowed, end - index >= 3 {
                    // Correct a single adjacent-letter transposition (hoa→hao, zhogn→zhong).
                    for corrected in transposedVariants(of: token) {
                        found = true
                        extend(corrected, to: end, fuzzy: 0, partial: 0, typo: 1)
                    }
                }
                for equivalent in fuzzyEquivalents(of: token, rules: fuzzy) where syllables.contains(equivalent) {
                    found = true
                    extend(equivalent, to: end, fuzzy: 1, partial: 0, typo: 0)
                }
            }
            let initial = String(chars[index])
            if initials.contains(initial) {
                found = true
                extend(initial, to: index + 1, fuzzy: 0, partial: 1, typo: 0)
            }
            if !found, index > 0 {
                // Dead end after at least one syllable: keep the truncated parse, flagged partial.
                candidates.append(([], index, 0, 1, 0))
            }
            candidates.sort(by: better)
            var unique: [Part] = []
            var seen = Set<[String]>()
            for candidate in candidates where seen.insert(candidate.syllables).inserted {
                unique.append(candidate)
                if unique.count == limit { break }
            }
            memo[key] = unique
            return unique
        }

        return best(0, typoAllowed: true).compactMap { part in
            part.syllables.isEmpty ? nil : SegmentationPath(
                syllables: part.syllables, consumedLength: part.end, fuzzyMatches: part.fuzzy,
                partialCount: part.partial, typoCount: part.typo
            )
        }
    }

    private func normalizedFullForm(of token: String) -> String? {
        for (fullForm, short) in Self.fullFormFinals where token.hasSuffix(fullForm) {
            let normalized = String(token.dropLast(fullForm.count)) + short
            if syllables.contains(normalized) { return normalized }
        }
        return nil
    }

    private func transposedVariants(of token: String) -> [String] {
        var variants: [String] = []
        var chars = Array(token)
        for index in 0..<(chars.count - 1) where chars[index] != chars[index + 1] {
            chars.swapAt(index, index + 1)
            let variant = String(chars)
            if syllables.contains(variant), !variants.contains(variant) { variants.append(variant) }
            chars.swapAt(index, index + 1)
        }
        return variants
    }

    private func fuzzyEquivalents(of token: String, rules: FuzzyRules) -> Set<String> {
        let pairs: [(Bool, String, String)] = [
            (rules.zZh, "z", "zh"), (rules.cCh, "c", "ch"), (rules.sSh, "s", "sh"),
            (rules.nL, "n", "l"), (rules.fH, "f", "h"), (rules.rL, "r", "l"),
            (rules.anAng, "an", "ang"), (rules.enEng, "en", "eng"),
            (rules.inIng, "in", "ing"), (rules.ianIang, "ian", "iang"),
            (rules.uanUang, "uan", "uang"),
        ]
        var values = Set<String>()
        for (enabled, lhs, rhs) in pairs where enabled {
            if token == lhs { values.insert(rhs) }
            if token == rhs { values.insert(lhs) }
            if token.hasPrefix(lhs) { values.insert(rhs + token.dropFirst(lhs.count)) }
            if token.hasPrefix(rhs) { values.insert(lhs + token.dropFirst(rhs.count)) }
            if token.hasSuffix(lhs) { values.insert(String(token.dropLast(lhs.count)) + rhs) }
            if token.hasSuffix(rhs) { values.insert(String(token.dropLast(rhs.count)) + lhs) }
        }
        values.remove(token)
        return values
    }

    private static func precedes(_ lhs: SegmentationPath, _ rhs: SegmentationPath) -> Bool {
        // Consuming more of the input always wins: a truncated parse must never
        // shadow a complete one (e.g. [wo,xian,za]+junk vs [wo,xian,zai,hen,m]).
        if lhs.consumedLength != rhs.consumedLength { return lhs.consumedLength > rhs.consumedLength }
        if lhs.partialCount != rhs.partialCount { return lhs.partialCount < rhs.partialCount }
        if lhs.typoCount != rhs.typoCount { return lhs.typoCount < rhs.typoCount }
        if lhs.fuzzyMatches != rhs.fuzzyMatches { return lhs.fuzzyMatches < rhs.fuzzyMatches }
        if lhs.syllables.count != rhs.syllables.count { return lhs.syllables.count < rhs.syllables.count }
        return lhs.preedit < rhs.preedit
    }
}

public enum PinyinTable {
    public static let syllables: Set<String> = Set(list.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let list = """
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
    ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo
    da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
    e ei en eng er fa fan fang fei fen feng fiao fo fou fu
    ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
    ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
    ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
    ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
    la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo lv lve
    ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
    na nai nan nang nao ne nei nen neng ng ni nian niang niao nie nin ning niu nong nou nu nuan nue nuo nv nve
    o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
    qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
    ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
    sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo
    ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
    wa wai wan wang wei wen weng wo wu
    xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
    ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
    za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
    """
}
