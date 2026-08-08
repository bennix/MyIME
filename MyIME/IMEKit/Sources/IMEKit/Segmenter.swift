import Foundation

public struct SegmentationPath: Equatable, Sendable {
    public let syllables: [String]
    public let consumedLength: Int
    public let fuzzyMatches: Int
    public let partialCount: Int

    public var preedit: String { syllables.joined(separator: "'") }
}

public struct Segmenter: Sendable {
    private let syllables: Set<String>
    private let initials = Set("bpmfdtnlgkhjqxzcsryw".map(String.init))

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
                        partialCount: prefix.partialCount + path.partialCount
                    )
                }
            }
            .sorted(by: Self.precedes)
            .prefix(limit)
            .map { $0 }
        }
        return combined.filter { !$0.syllables.isEmpty }.sorted(by: Self.precedes)
    }

    private func segmentPiece(_ text: String, fuzzy: FuzzyRules, limit: Int) -> [SegmentationPath] {
        let chars = Array(text)
        var results: [SegmentationPath] = []

        func walk(_ index: Int, _ path: [String], _ fuzzyCount: Int, _ partialCount: Int) {
            if results.count >= limit * 8 { return }
            if index == chars.count {
                results.append(SegmentationPath(syllables: path, consumedLength: index, fuzzyMatches: fuzzyCount, partialCount: partialCount))
                return
            }
            var found = false
            let maxEnd = min(chars.count, index + 6)
            if index < maxEnd {
                for end in stride(from: maxEnd, through: index + 1, by: -1) {
                    let token = String(chars[index..<end])
                    if syllables.contains(token) {
                        found = true
                        walk(end, path + [token], fuzzyCount, partialCount)
                    }
                    for equivalent in fuzzyEquivalents(of: token, rules: fuzzy) where syllables.contains(equivalent) {
                        found = true
                        walk(end, path + [equivalent], fuzzyCount + 1, partialCount)
                    }
                }
            }
            let initial = String(chars[index])
            if initials.contains(initial) {
                found = true
                walk(index + 1, path + [initial], fuzzyCount, partialCount + 1)
            }
            if !found, !path.isEmpty {
                results.append(SegmentationPath(syllables: path, consumedLength: index, fuzzyMatches: fuzzyCount, partialCount: partialCount + 1))
            }
        }

        walk(0, [], 0, 0)
        return Array(results.sorted(by: Self.precedes).prefix(limit))
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
        if lhs.partialCount != rhs.partialCount { return lhs.partialCount < rhs.partialCount }
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
