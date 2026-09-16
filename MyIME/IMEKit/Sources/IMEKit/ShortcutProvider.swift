import Foundation

enum ShortcutProvider {
    static func addingShortcuts(
        to candidates: [Candidate],
        for input: String,
        date: Date = Date(),
        calendar: Calendar = .current,
        limit: Int
    ) -> [Candidate] {
        let words = shortcutWords(for: input, date: date, calendar: calendar)
        guard !words.isEmpty else { return candidates }
        let shortcuts = words.enumerated().map { index, word in
            Candidate(
                id: Int64.min / 4 + Int64(index),
                word: word,
                pinyinPath: [],
                score: .greatestFiniteMagnitude - Double(index),
                consumedLength: input.count
            )
        }
        let insertion = min(1, candidates.count)
        var result = candidates
        // Keep the primary shortcut easy to reach without pushing ordinary
        // abbreviation matches out of the first page. Alternate formats follow.
        result.insert(shortcuts[0], at: insertion)
        result.insert(contentsOf: shortcuts.dropFirst(), at: min(8, result.count))
        return Array(result.prefix(limit))
    }

    static func shortcutWords(
        for input: String,
        date: Date,
        calendar: Calendar
    ) -> [String] {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return [] }
        switch input {
        case "rq":
            return [
                "\(year)年\(month)月\(day)日",
                String(format: "%04d-%02d-%02d", year, month, day),
                String(format: "%04d/%02d/%02d", year, month, day),
            ]
        case "sj":
            guard let hour = components.hour, let minute = components.minute, let second = components.second else { return [] }
            return [
                String(format: "%02d:%02d", hour, minute),
                String(format: "%02d:%02d:%02d", hour, minute, second),
                "\(hour)点\(String(format: "%02d", minute))分",
            ]
        case "xq":
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            guard let weekday = components.weekday, names.indices.contains(weekday - 1) else { return [] }
            return ["星期\(names[weekday - 1])", "周\(names[weekday - 1])"]
        default:
            return []
        }
    }
}
