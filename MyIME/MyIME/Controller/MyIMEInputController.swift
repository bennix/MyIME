import AppKit
import Carbon
import InputMethodKit
import IMEKit
import os

@objc(MyIMEInputController)
final class MyIMEInputController: IMKInputController {
    private static weak var activatedController: MyIMEInputController?
    private static let liveControllers = NSHashTable<MyIMEInputController>.weakObjects()
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
    private var showingSuggestions = false
    private var didLogInputPath = false
    private var diagnosticEventCount = 0
    // Keep the IMK client proxy alive between key callbacks and palette clicks.
    // Release it in deactivateServer when the session loses focus.
    private var activeClient: (any IMKTextInput)?

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        Self.liveControllers.add(self)
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

    private func textClient(from sender: Any?) -> (any IMKTextInput)? {
        (sender as? any IMKTextInput) ?? client()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        englishMode = false
        shiftWasDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        shiftUsedWithKey = false
        if let client = textClient(from: sender) {
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
        logInputPath("NSEvent")
        guard let event, let client = textClient(from: sender) else { return false }
        activeClient = client
        logger.debug("收到输入事件：type=\(event.type.rawValue), keyCode=\(event.keyCode)")
        return safelyHandle(event, client: client)
    }

    // WebKit/Electron can request text-data delivery instead of NSEvent delivery.
    // Route all delivery modes through the same composition/selection behavior.
    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        logInputPath("text-data")
        if diagnosticEventCount < 3 {
            diagnosticEventCount += 1
            logger.notice("输入回调状态：client=\(self.textClient(from: sender) != nil), key=\(keyCode), flags=\(flags), textPresent=\(string != nil)")
        }
        guard let client = textClient(from: sender),
              (0...Int(UInt16.max)).contains(keyCode) else { return false }
        activeClient = client
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: flags)),
            timestamp: 0, windowNumber: 0, context: nil,
            characters: string ?? "", charactersIgnoringModifiers: string ?? "",
            isARepeat: false, keyCode: UInt16(keyCode)
        ) else { return false }
        return safelyHandle(event, client: client)
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        logInputPath("text-only")
        if string == "\u{1b}", let client = textClient(from: sender) {
            reset(client)
            return true
        }
        guard let string, !string.isEmpty, !englishMode,
              let client = textClient(from: sender) else { return false }
        activeClient = client
        for character in string {
            let key: Int
            switch character {
            case " ": key = 49
            case "\n", "\r": key = 36
            case "\u{7f}", "\u{8}": key = 51
            case "\u{1b}": key = 53
            default: key = 0
            }
            if !inputText(String(character), key: key, modifiers: 0, client: client) {
                client.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            }
        }
        return true
    }

    private func logInputPath(_ path: String) {
        guard !didLogInputPath else { return }
        didLogInputPath = true
        logger.notice("输入会话事件路径：\(path, privacy: .public)")
    }

    override func didCommand(by selector: Selector!, client sender: Any!) -> Bool {
        guard let selector else { return false }
        let keyCodes: [String: Int] = [
            "deleteBackward:": 51, "cancelOperation:": 53, "cancel:": 53,
            "insertNewline:": 36, "insertLineBreak:": 36,
            "moveLeft:": 123, "moveRight:": 124, "moveDown:": 125, "moveUp:": 126,
            "pageUp:": 116, "pageDown:": 121,
        ]
        guard let key = keyCodes[NSStringFromSelector(selector)] else { return false }
        return inputText("", key: key, modifiers: 0, client: sender)
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
        guard let client = textClient(from: sender) else {
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
        if !SelfInstaller.isCurrentInputSource {
            // Text-data clients may never call activateServer. Hide every live
            // session, including those not tracked as the activated controller.
            for controller in liveControllers.allObjects {
                controller.hidePalettes()
            }
        }
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
        guard let client = textClient(from: sender) else { return }
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
                    if englishMode {
                        inputModeIndicator.hide()
                    } else {
                        inputModeIndicator.show(client: client)
                    }
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
            if raw.isEmpty {
                if showingSuggestions, !output.candidates.isEmpty {
                    commitSuggestion(highlighted, client: client)
                    return true
                }
                engine.breakPhraseLearningContext()
                clearSuggestions()
                return false
            }
            commitHighlighted(client)
            return true
        case 36, 76: // Return / keypad enter
            defer { clearSuggestions(); inputModeIndicator.hide() }
            if raw.isEmpty {
                if showingSuggestions {
                    return true
                }
                return false
            }
            if hasNavigatedCandidates {
                commitHighlighted(client)
            } else {
                commit(composedPhrase + raw, pinyin: [], client: client, learn: false)
            }
            return true
        case 51: // Backspace
            if raw.isEmpty {
                if showingSuggestions {
                    clearSuggestions()
                    return true
                }
                return false
            }
            raw.removeLast()
            refresh(client)
            return true
        case 53: // Escape
            let hadCandidates = !raw.isEmpty || showingSuggestions || !composedPhrase.isEmpty
            reset(client)
            return hadCandidates
        case 123: // Left
            return moveHighlight(-1)
        case 124: // Right
            return moveHighlight(1)
        case 125: // Down
            return moveDown()
        case 126: // Up
            return moveUp()
        case 27, 43, 116: // - or , or Page Up
            return movePage(-1)
        case 24, 47, 121: // = or . or Page Down
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

        if let number = character.wholeNumberValue, (!raw.isEmpty || showingSuggestions) {
            let maximumNumber = expandedCandidates ? 6 : 9
            guard (1...maximumNumber).contains(number) else { return false }
            let activeRowStart = expandedCandidates ? highlighted / 6 * 6 : 0
            if showingSuggestions, raw.isEmpty {
                commitSuggestion(activeRowStart + number - 1, client: client)
            } else {
                selectVisible(activeRowStart + number - 1, client: client)
            }
            return true
        }
        if !raw.isEmpty, !character.isWhitespace, character.isASCII {
            commitHighlighted(client)
            client.insertText(localizedPunctuation(for: character), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            engine.breakPhraseLearningContext()
            clearSuggestions()
            return true
        }
        if character.isWhitespace || !character.isLetter {
            engine.breakPhraseLearningContext()
            clearSuggestions()
        }
        return false
    }

    private func refresh(_ client: IMKTextInput) {
        inputModeIndicator.hide()
        showingSuggestions = false
        let prefs = PreferencesStore.load()
        output = addingEnglishCandidates(to: engine.update(raw, prefs: prefs))
        page = 0
        highlighted = 0
        expandedCandidates = false
        hasNavigatedCandidates = false
        let converted = localized(composedPhrase, prefs: prefs)
        let marked = NSMutableAttributedString(string: converted + (output.preedit.isEmpty ? raw : output.preedit))
        let convertedLength = converted.utf16.count
        for (range, style) in [
            (NSRange(location: 0, length: convertedLength), kTSMHiliteConvertedText),
            (NSRange(location: convertedLength, length: marked.length - convertedLength), kTSMHiliteSelectedRawText),
        ] where range.length > 0 {
            if let attributes = mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any] {
                marked.setAttributes(attributes, range: range)
            }
        }
        client.setMarkedText(marked, selectionRange: NSRange(location: marked.length, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
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
        if candidate.pinyinPath.isEmpty, result.remainingRaw.isEmpty {
            // Dates and other literal shortcuts must not become a learned
            // phrase under the pinyin of a previously selected fragment.
            commit(composedPhrase + result.commitText, pinyin: [], client: client, learn: false)
            return
        }
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
            commit(composedPhrase, pinyin: composedPinyin, client: client, learn: false, suggest: !composedPinyin.isEmpty)
        } else {
            refresh(client)
        }
    }

    private func commit(_ text: String, pinyin: [String], client: IMKTextInput, learn: Bool, suggest: Bool = false) {
        let committedText = localized(text, prefs: PreferencesStore.load())
        client.insertText(committedText, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        if learn { engine.commitLearning(word: text, pinyin: pinyin) }
        if pinyin.isEmpty { engine.breakPhraseLearningContext() }
        raw = ""
        composedPhrase = ""
        composedPinyin = []
        hasNavigatedCandidates = false
        expandedCandidates = false
        if suggest || learn {
            showSuggestions(client)
        } else {
            clearSuggestions()
        }
        if !englishMode, !showingSuggestions, Self.activatedController === self, SelfInstaller.isCurrentInputSource {
            inputModeIndicator.show(client: client)
        }
    }

    private func showSuggestions(_ client: IMKTextInput) {
        inputModeIndicator.hide()
        let prefs = PreferencesStore.load()
        let suggestions = engine.suggestions(limit: max(36, prefs.pageSize))
        guard !suggestions.isEmpty else {
            clearSuggestions()
            return
        }
        showingSuggestions = true
        output = EngineOutput(preedit: "", candidates: suggestions, hasMore: false, raw: "")
        page = 0
        highlighted = 0
        expandedCandidates = false
        hasNavigatedCandidates = false
        candidateWindow.update(
            candidates: localizedCandidates(visibleCandidates, prefs: prefs),
            highlighted: highlighted,
            prefs: prefs,
            expanded: false,
            client: client
        )
    }

    private func clearSuggestions() {
        showingSuggestions = false
        output = EngineOutput(preedit: "", candidates: [], hasMore: false, raw: "")
        page = 0
        highlighted = 0
        candidateWindow.hide()
    }

    private func commitSuggestion(_ visibleIndex: Int, client: IMKTextInput) {
        let index = page * candidatePageSize + visibleIndex
        guard showingSuggestions, output.candidates.indices.contains(index) else { return }
        let suggestion = output.candidates[index]
        let prefs = PreferencesStore.load()
        client.insertText(
            localized(suggestion.word, prefs: prefs),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
        engine.commitLearning(word: suggestion.word, pinyin: [])
        showSuggestions(client)
    }

    private func reset(_ client: IMKTextInput) {
        engine.breakPhraseLearningContext()
        raw = ""
        page = 0
        highlighted = 0
        expandedCandidates = false
        composedPhrase = ""
        composedPinyin = []
        hasNavigatedCandidates = false
        client.setMarkedText(NSAttributedString(string: ""), selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        clearSuggestions()
    }

    private func moveHighlight(_ delta: Int) -> Bool {
        let candidates = visibleCandidates
        guard (!raw.isEmpty || showingSuggestions), !candidates.isEmpty else { return false }
        highlighted = min(max(0, highlighted + delta), candidates.count - 1)
        hasNavigatedCandidates = true
        candidateWindow.updateHighlight(highlighted)
        return true
    }

    private func moveDown() -> Bool {
        guard !raw.isEmpty || showingSuggestions else { return false }
        if !expandedCandidates {
            expandedCandidates = true
            page = 0
            highlighted = 0
            refreshCandidateWindowPosition()
            return true
        }
        return moveHighlight(candidateWindow.verticalLayout ? 1 : 6)
    }

    private func moveUp() -> Bool {
        guard !raw.isEmpty || showingSuggestions else { return false }
        guard expandedCandidates else { return false }
        let step = candidateWindow.verticalLayout ? 1 : 6
        return highlighted >= step ? moveHighlight(-step) : true
    }

    private func collapseCandidates() {
        guard (!raw.isEmpty || showingSuggestions), expandedCandidates else { return }
        expandedCandidates = false
        page = 0
        highlighted = 0
        refreshCandidateWindowPosition()
    }

    private func movePage(_ delta: Int) -> Bool {
        guard !raw.isEmpty || showingSuggestions else { return false }
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
                consumedLength: candidate.consumedLength,
                gloss: candidate.gloss
            )
        }
    }
}
