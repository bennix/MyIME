import Foundation

public struct TraditionalConverter: Sendable {
    public static let empty = TraditionalConverter(mappings: [:])

    private let mappings: [String: String]
    private let maximumKeyLength: Int

    public init(mappings: [String: String]) {
        self.mappings = mappings
        maximumKeyLength = mappings.keys.map(\.count).max() ?? 1
    }

    public var isAvailable: Bool { !mappings.isEmpty }

    public func convert(_ text: String) -> String {
        guard !text.isEmpty, !mappings.isEmpty else { return text }
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let maximumLength = min(maximumKeyLength, characters.count - index)
            var matched = false
            for length in stride(from: maximumLength, through: 1, by: -1) {
                let key = String(characters[index..<(index + length)])
                guard let replacement = mappings[key] else { continue }
                result += replacement
                index += length
                matched = true
                break
            }
            if !matched {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }
}
