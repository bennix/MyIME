import AppKit
import InputMethodKit
import IMEKit
import os

@objc(MyIMEInputController)
final class MyIMEInputController: IMKInputController {
    private static weak var activatedController: MyIMEInputController?
    private let engine = IMEEnvironment.shared.engine
    private let traditionalConverter = IMEEnvironment.shared.systemStore?.traditionalConverter ?? .empty
    private let candidateWindow = CandidateWindowController()
    private let inputModeIndicator = InputModeIndicatorController()
    private let logger = Logger(subsystem: "fudan.miniS.MyIME", category: "input")
    private var raw = ""
    private var output = EngineOutput(preedit: "", candidates: [], hasMore: false, raw: "")
    private var page = 0
    private var highlighted = 0
    private var expandedCandidates = false
    private var englishMode = false
    private var shiftWasDown = false
    private var shiftUsedWithKey = false
    private var composedPhrase = ""
    private var composedPinyin: [String] = []
    private var hasNavigatedCandidates = false
    private weak var activeClient: (any IMKTextInput)?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        candidateWindow.onExpand = { [weak self] in
            _ = self?.moveDown()
        }
        candidateWindow.onCollapse = { [weak self] in self?.collapseCandidates() }
        candidateWindow.onSelect = { [weak self] index in
            guard let self, let client = self.activeClient else { return }
            self.selectVisible(index, client: client)
        }
        logger.notice("输入会话已建立")
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        englishMode = false
        shiftWasDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        shiftUsedWithKey = false
        if let client = sender as? IMKTextInput {
            activeClient = client
            Self.activatedController = self
            client.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")
            let bundleID = client.bundleIdentifier() ?? "未知应用"
            logger.notice("输入法已在 \(bundleID, privacy: .public) 激活")
            inputModeIndicator.show(client: client)
        } else {
            logger.error("输入法已激活，但没有可用的文本客户端")
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        activeClient = client
        logger.debug("收到输入事件：type=\(event.type.rawValue), keyCode=\(event.keyCode)")
        return safelyHandle(event, client: client)
    }

    override func deactivateServer(_ sender: Any!) {
        engine.breakPhraseLearningContext()
        inputModeIndicator.hide()
        candidateWindow.hide()
        shiftWasDown = false
        shiftUsedWithKey = false
        defer {
            if Self.activatedController === self {
                Self.activatedController = nil
            }
            activeClient = nil
        }
        guard let client = sender as? IMKTextInput else {
            super.deactivateServer(sender)
            return
        }
        if !raw.isEmpty || !composedPhrase.isEmpty {
            commit(composedPhrase + raw, pinyin: [], client: client, learn: false)
        }
        super.deactivateServer(sender)
    }

    override func hidePalettes() {
        inputModeIndicator.hide()
        candidateWindow.hide()
        super.hidePalettes()
    }

    static func finalizeStrandedCompositionIfNeeded() {
        guard !SelfInstaller.isCurrentInputSource,
              let controller = activatedController else { return }
        if let client = controller.activeClient {
            controller.deactivateServer(client)
        } else {
            controller.hidePalettes()
            activatedController = nil
        }
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        if !raw.isEmpty || !composedPhrase.isEmpty {
            commit(composedPhrase + raw, pinyin: [], client: client, learn: false)
        }
    }

    private func safelyHandle(_ event: NSEvent, client: IMKTextInput) -> Bool {
        if event.type == .flagsChanged, event.keyCode == 56 || event.keyCode == 60 {
            let shiftIsDown = event.modifierFlags.contains(.shift)
            if shiftIsDown, !shiftWasDown {
                shiftUsedWithKey = false
            }
            if shiftWasDown, !shiftIsDown {
                if !shiftUsedWithKey {
                    if !raw.isEmpty { commit(composedPhrase + raw, pinyin: [], client: client, learn: false) }
                    englishMode.toggle()
                }
                shiftUsedWithKey = false
            }
            shiftWasDown = shiftIsDown
            return false
        }
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) { return false }
        if modifiers.contains(.shift) {
            shiftUsedWithKey = true
        }
        switch event.keyCode {
        case 49: // Space
            guard !raw.isEmpty else {
                engine.breakPhraseLearningContext()
                return false
            }
            commitHighlighted(client)
            return true
        case 36, 76: // Return / keypad enter
            guard !raw.isEmpty else { return false }
            if hasNavigatedCandidates {
                commitHighlighted(client)
            } else {
                commit(composedPhrase + raw, pinyin: [], client: client, learn: false)
            }
            return true
        case 51: // Backspace
            guard !raw.isEmpty else { return false }
            raw.removeLast()
            refresh(client)
            return true
        case 53: // Escape
            guard !raw.isEmpty else { return false }
            reset(client)
            return true
        case 123: // Left
            return moveHighlight(-1)
        case 124: // Right
            return moveHighlight(1)
        case 125: // Down
            return moveDown()
        case 126: // Up
            return moveUp()
        case 27, 43: // - or ,
            return movePage(-1)
        case 24, 47: // = or .
            return movePage(1)
        default:
            break
        }
        if modifiers.contains(.shift) {
            if !raw.isEmpty { commit(composedPhrase + raw, pinyin: [], client: client, learn: false) }
            return false
        }
        guard let characters = event.charactersIgnoringModifiers, let character = characters.first else { return false }
        if englishMode { return false }

        if character.isASCII, character.isLetter {
            if raw.isEmpty {
                composedPhrase = ""
                composedPinyin = []
            }
            raw.append(String(character).lowercased())
            refresh(client)
            return true
        }
        if character == "'" {
            guard !raw.isEmpty else { return false }
            raw.append(character)
            refresh(client)
            return true
        }

        if let number = character.wholeNumberValue, !raw.isEmpty {
            let maximumNumber = expandedCandidates ? 6 : 9
            guard (1...maximumNumber).contains(number) else { return false }
            let activeRowStart = expandedCandidates ? highlighted / 6 * 6 : 0
            selectVisible(activeRowStart + number - 1, client: client)
            return true
        }
        if !raw.isEmpty, !character.isWhitespace, character.isASCII {
            commitHighlighted(client)
            client.insertText(localizedPunctuation(for: character), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            engine.breakPhraseLearningContext()
            return true
        }
        if character.isWhitespace || !character.isLetter {
            engine.breakPhraseLearningContext()
        }
        return false
    }

    private func refresh(_ client: IMKTextInput) {
        let prefs = PreferencesStore.load()
        output = addingEnglishCandidates(to: engine.update(raw, prefs: prefs))
        page = 0
        highlighted = 0
        expandedCandidates = false
        hasNavigatedCandidates = false
        let marked = localized(composedPhrase, prefs: prefs) + (output.preedit.isEmpty ? raw : output.preedit)
        client.setMarkedText(marked, selectionRange: NSRange(location: marked.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        candidateWindow.update(
            candidates: localizedCandidates(visibleCandidates, prefs: prefs),
            highlighted: highlighted,
            prefs: prefs,
            expanded: expandedCandidates,
            client: client
        )
    }

    private var visibleCandidates: [Candidate] {
        let pageSize = candidatePageSize
        let start = min(page * pageSize, output.candidates.count)
        return Array(output.candidates.dropFirst(start).prefix(pageSize))
    }

    private func commitHighlighted(_ client: IMKTextInput) {
        guard !visibleCandidates.isEmpty else {
            commit(composedPhrase + raw, pinyin: [], client: client, learn: false)
            return
        }
        selectVisible(highlighted, client: client)
    }

    private func selectVisible(_ visibleIndex: Int, client: IMKTextInput) {
        let pageSize = candidatePageSize
        let index = page * pageSize + visibleIndex
        guard output.candidates.indices.contains(index) else { return }
        let candidate = output.candidates[index]
        let result = engine.select(index, from: output)
        guard !result.commitText.isEmpty else { return }
        if !candidate.pinyinPath.isEmpty {
            engine.commitLearning(word: candidate.word, pinyin: candidate.pinyinPath)
        }
        composedPhrase += candidate.word
        composedPinyin += candidate.pinyinPath
        raw = result.remainingRaw
        if raw.isEmpty {
            if !composedPinyin.isEmpty {
                engine.commitUserPhrase(word: composedPhrase, pinyin: composedPinyin)
            }
            commit(composedPhrase, pinyin: composedPinyin, client: client, learn: false)
        } else {
            refresh(client)
        }
    }

    private func commit(_ text: String, pinyin: [String], client: IMKTextInput, learn: Bool) {
        let committedText = localized(text, prefs: PreferencesStore.load())
        client.insertText(committedText, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        if learn { engine.commitLearning(word: text, pinyin: pinyin) }
        if pinyin.isEmpty { engine.breakPhraseLearningContext() }
        raw = ""
        output = EngineOutput(preedit: "", candidates: [], hasMore: false, raw: "")
        composedPhrase = ""
        composedPinyin = []
        hasNavigatedCandidates = false
        candidateWindow.hide()
    }

    private func reset(_ client: IMKTextInput) {
        engine.breakPhraseLearningContext()
        raw = ""
        output = EngineOutput(preedit: "", candidates: [], hasMore: false, raw: "")
        page = 0
        highlighted = 0
        expandedCandidates = false
        composedPhrase = ""
        composedPinyin = []
        hasNavigatedCandidates = false
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        candidateWindow.hide()
    }

    private func moveHighlight(_ delta: Int) -> Bool {
        let candidates = visibleCandidates
        guard !raw.isEmpty, !candidates.isEmpty else { return false }
        highlighted = min(max(0, highlighted + delta), candidates.count - 1)
        hasNavigatedCandidates = true
        candidateWindow.updateHighlight(highlighted)
        return true
    }

    private func moveDown() -> Bool {
        guard !raw.isEmpty else { return false }
        if !expandedCandidates {
            expandedCandidates = true
            page = 0
            highlighted = 0
            refreshCandidateWindowPosition()
            return true
        }
        return moveHighlight(6)
    }

    private func moveUp() -> Bool {
        guard !raw.isEmpty, expandedCandidates else { return false }
        return highlighted >= 6 ? moveHighlight(-6) : true
    }

    private func collapseCandidates() {
        guard !raw.isEmpty, expandedCandidates else { return }
        expandedCandidates = false
        page = 0
        highlighted = 0
        refreshCandidateWindowPosition()
    }

    private func movePage(_ delta: Int) -> Bool {
        guard !raw.isEmpty else { return false }
        let pageSize = candidatePageSize
        let maxPage = max(0, (output.candidates.count - 1) / pageSize)
        let newPage = min(max(0, page + delta), maxPage)
        guard newPage != page else { return true }
        page = newPage
        highlighted = 0
        hasNavigatedCandidates = true
        refreshCandidateWindowPosition()
        return true
    }

    private func refreshCandidateWindowPosition() {
        guard let client = activeClient else { return }
        let prefs = PreferencesStore.load()
        candidateWindow.update(
            candidates: localizedCandidates(visibleCandidates, prefs: prefs),
            highlighted: highlighted,
            prefs: prefs,
            expanded: expandedCandidates,
            client: client
        )
    }

    private var candidatePageSize: Int {
        expandedCandidates ? 36 : PreferencesStore.load().pageSize
    }

    private func addingEnglishCandidates(to base: EngineOutput) -> EngineOutput {
        guard raw.count >= 2, raw.allSatisfy({ $0.isASCII && $0.isLetter }) else { return base }
        let checker = NSSpellChecker.shared
        let fullRange = NSRange(location: 0, length: raw.utf16.count)
        let misspelled = checker.checkSpelling(
            of: raw,
            startingAt: 0,
            language: "en_US",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let words: [String]
        if misspelled.location == NSNotFound {
            words = [raw]
        } else {
            words = Array((checker.guesses(
                forWordRange: fullRange,
                in: raw,
                language: "en_US",
                inSpellDocumentWithTag: 0
            ) ?? []).prefix(2))
        }
        let uniqueWords = words.reduce(into: [String]()) { result, word in
            if !result.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                result.append(word)
            }
        }
        guard !uniqueWords.isEmpty else { return base }

        var candidates = base.candidates
        let insertionIndex = min(3, candidates.count)
        let englishCandidates = uniqueWords.enumerated().map { index, word in
            Candidate(
                id: Int64.min / 2 + Int64(index),
                word: word,
                pinyinPath: [],
                score: 0,
                consumedLength: raw.count
            )
        }
        candidates.insert(contentsOf: englishCandidates, at: insertionIndex)
        return EngineOutput(
            preedit: base.preedit,
            candidates: Array(candidates.prefix(100)),
            hasMore: base.hasMore || candidates.count > 100,
            raw: base.raw
        )
    }

    private func localizedPunctuation(for character: Character) -> String {
        let values: [Character: String] = [",": "，", ".": "。", "?": "？", "!": "！", ";": "；", ":": "：", "(": "（", ")": "）"]
        return values[character] ?? String(character)
    }

    private func localized(_ text: String, prefs: EnginePrefs) -> String {
        prefs.outputTraditional ? traditionalConverter.convert(text) : text
    }

    private func localizedCandidates(_ candidates: [Candidate], prefs: EnginePrefs) -> [Candidate] {
        guard prefs.outputTraditional, traditionalConverter.isAvailable else { return candidates }
        return candidates.map { candidate in
            Candidate(
                id: candidate.id,
                word: traditionalConverter.convert(candidate.word),
                pinyinPath: candidate.pinyinPath,
                score: candidate.score,
                consumedLength: candidate.consumedLength
            )
        }
    }
}
