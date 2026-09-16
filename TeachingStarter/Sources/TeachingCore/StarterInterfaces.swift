import Foundation

// MARK: - Lab 1: IMK boundary

public protocol EchoEventHandling {
    /// Return true only when the IME owns and handles the event.
    func handlePrintableASCII(_ character: Character) -> Bool
}

// MARK: - Lab 2: composition state

public enum InputAction: Equatable, Sendable {
    case append(Character)
    case deleteBackward
    case commit
    case cancel
}

public enum Effect: Equatable, Sendable {
    case updateMarked(String)
    case insert(String)
    case clearMarked
    case none
}

public struct CompositionState: Equatable, Sendable {
    public var raw = ""

    public init() {}

    /// Lab 2 TODO: implement the transition table before connecting AppKit.
    public mutating func reduce(_ action: InputAction) -> Effect {
        _ = action
        return .none
    }
}

// MARK: - Labs 3–4: candidates and pure coordinate fixtures

public struct LexiconEntry: Equatable, Sendable {
    public let pinyin: String
    public let text: String
    public let frequency: Int

    public init(pinyin: String, text: String, frequency: Int) {
        self.pinyin = pinyin
        self.text = text
        self.frequency = frequency
    }
}

public protocol CandidateProviding: Sendable {
    func candidates(for raw: String) -> [LexiconEntry]
}

public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public protocol CandidatePositioning: Sendable {
    func panelOrigin(lineRect: Rect, panelSize: (width: Double, height: Double), visibleFrame: Rect) -> (x: Double, y: Double)
}

// MARK: - Labs 5–7: graph search and scoring

public struct SyllableEdge: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let syllable: String
    public let penalty: Double

    public init(start: Int, end: Int, syllable: String, penalty: Double = 0) {
        self.start = start
        self.end = end
        self.syllable = syllable
        self.penalty = penalty
    }
}

public struct ScoreBreakdown: Equatable, Sendable {
    public var frequency = 0.0
    public var user = 0.0
    public var context = 0.0
    public var fuzzy = 0.0
    public var typo = 0.0
    public var partial = 0.0
    public var incomplete = 0.0
    public var completion = 0.0

    public init() {}

    public var total: Double {
        frequency + user + context - fuzzy - typo - partial - incomplete - completion
    }
}

public struct LatticeEdge: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let text: String
    public let score: Double

    public init(start: Int, end: Int, text: String, score: Double) {
        self.start = start
        self.end = end
        self.text = text
        self.score = score
    }
}

public struct Hypothesis: Equatable, Sendable {
    public let position: Int
    public let text: String
    public let score: Double
    public let lastWord: String?

    public init(position: Int, text: String, score: Double, lastWord: String?) {
        self.position = position
        self.text = text
        self.score = score
        self.lastWord = lastWord
    }
}

// MARK: - Labs 8–12: persistence, evidence, supply chain and release

public protocol LearningStore: Sendable {
    func learn(word: String, previousWord: String?) async throws
    func clear() async throws
}

public struct CompatibilityCase: Equatable, Sendable {
    public let client: String
    public let input: String
    public let expectedCommit: String
    public let requiresVoiceOverCheck: Bool

    public init(client: String, input: String, expectedCommit: String, requiresVoiceOverCheck: Bool = false) {
        self.client = client
        self.input = input
        self.expectedCommit = expectedCommit
        self.requiresVoiceOverCheck = requiresVoiceOverCheck
    }
}

public struct DiagnosticSnapshot: Codable, Equatable, Sendable {
    public var appVersion: String
    public var macOSBuild: String
    public var architecture: String
    public var inputSourceID: String
    public var redactedLogLines: [String]

    public init(appVersion: String, macOSBuild: String, architecture: String, inputSourceID: String, redactedLogLines: [String]) {
        self.appVersion = appVersion
        self.macOSBuild = macOSBuild
        self.architecture = architecture
        self.inputSourceID = inputSourceID
        self.redactedLogLines = redactedLogLines
    }
}

public struct DependencyRecord: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let license: String
    public let sha256: String

    public init(name: String, version: String, license: String, sha256: String) {
        self.name = name
        self.version = version
        self.license = license
        self.sha256 = sha256
    }
}

public enum ReleaseCheck: String, CaseIterable, Codable, Sendable {
    case tests
    case universalArchitecture
    case developerID
    case notarization
    case stapling
    case checksum
    case cleanMacInstall
    case processRecovery
}
