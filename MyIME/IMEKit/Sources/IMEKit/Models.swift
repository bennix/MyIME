import Foundation

public struct Candidate: Hashable, Sendable {
    public let id: Int64
    public let word: String
    public let pinyinPath: [String]
    public let score: Double
    public let consumedLength: Int
    public let gloss: String?

    public init(id: Int64, word: String, pinyinPath: [String], score: Double, consumedLength: Int, gloss: String? = nil) {
        self.id = id
        self.word = word
        self.pinyinPath = pinyinPath
        self.score = score
        self.consumedLength = consumedLength
        self.gloss = gloss
    }
}

public struct EngineOutput: Sendable {
    public let preedit: String
    public let candidates: [Candidate]
    public let hasMore: Bool
    public let raw: String

    public init(preedit: String, candidates: [Candidate], hasMore: Bool, raw: String) {
        self.preedit = preedit
        self.candidates = candidates
        self.hasMore = hasMore
        self.raw = raw
    }
}

public struct SelectResult: Sendable {
    public let commitText: String
    public let remainingRaw: String

    public init(commitText: String, remainingRaw: String) {
        self.commitText = commitText
        self.remainingRaw = remainingRaw
    }
}

public struct FuzzyRules: Codable, Equatable, Sendable {
    public var zZh = false
    public var cCh = false
    public var sSh = false
    public var nL = false
    public var fH = false
    public var rL = false
    public var anAng = false
    public var enEng = false
    public var inIng = false
    public var ianIang = false
    public var uanUang = false

    public init() {}
}

public enum CandidateOrientation: String, Codable, CaseIterable, Sendable {
    case horizontal
    case vertical
}

public struct EnginePrefs: Codable, Equatable, Sendable {
    public var pageSize = 5
    public var fuzzy = FuzzyRules()
    public var disabledSourceMask = 0
    public var fontSize = 18.0
    public var followsSystemAppearance = true
    public var orientation = CandidateOrientation.horizontal
    public var outputTraditional = false
    public var showEnglishGloss = true
    public var frequencyWeight = 1.0
    public var userWeight = 0.35
    public var lengthWeight = 0.12
    public var contextWeight = 0.2
    public var fuzzyPenalty = 0.08
    public var partialPenalty = 0.1

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case pageSize, fuzzy, disabledSourceMask, fontSize, followsSystemAppearance
        case orientation, outputTraditional, showEnglishGloss, frequencyWeight
        case userWeight, lengthWeight, contextWeight, fuzzyPenalty, partialPenalty
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pageSize = try values.decodeIfPresent(Int.self, forKey: .pageSize) ?? pageSize
        fuzzy = try values.decodeIfPresent(FuzzyRules.self, forKey: .fuzzy) ?? fuzzy
        disabledSourceMask = try values.decodeIfPresent(Int.self, forKey: .disabledSourceMask) ?? disabledSourceMask
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        followsSystemAppearance = try values.decodeIfPresent(Bool.self, forKey: .followsSystemAppearance) ?? followsSystemAppearance
        orientation = try values.decodeIfPresent(CandidateOrientation.self, forKey: .orientation) ?? orientation
        outputTraditional = try values.decodeIfPresent(Bool.self, forKey: .outputTraditional) ?? outputTraditional
        showEnglishGloss = try values.decodeIfPresent(Bool.self, forKey: .showEnglishGloss) ?? showEnglishGloss
        frequencyWeight = try values.decodeIfPresent(Double.self, forKey: .frequencyWeight) ?? frequencyWeight
        userWeight = try values.decodeIfPresent(Double.self, forKey: .userWeight) ?? userWeight
        lengthWeight = try values.decodeIfPresent(Double.self, forKey: .lengthWeight) ?? lengthWeight
        contextWeight = try values.decodeIfPresent(Double.self, forKey: .contextWeight) ?? contextWeight
        fuzzyPenalty = try values.decodeIfPresent(Double.self, forKey: .fuzzyPenalty) ?? fuzzyPenalty
        partialPenalty = try values.decodeIfPresent(Double.self, forKey: .partialPenalty) ?? partialPenalty
    }
}

public enum PreferencesStore {
    public static let suiteName = "group.fudan.miniS.MyIME"
    private static let key = "enginePreferences"

    public static func load() -> EnginePrefs {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: key),
              let value = try? JSONDecoder().decode(EnginePrefs.self, from: data) else {
            return EnginePrefs()
        }
        return value
    }

    public static func save(_ preferences: EnginePrefs) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
        NotificationCenter.default.post(name: .enginePreferencesDidChange, object: nil)
    }
}

public extension Notification.Name {
    static let enginePreferencesDidChange = Notification.Name("MyIME.enginePreferencesDidChange")
}

public protocol IMEEngine: AnyObject {
    func update(_ raw: String, prefs: EnginePrefs) -> EngineOutput
    func select(_ index: Int, from output: EngineOutput) -> SelectResult
    func commitLearning(word: String, pinyin: [String])
}
