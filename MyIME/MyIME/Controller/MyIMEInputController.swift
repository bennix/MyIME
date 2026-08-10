import AppKit
import Carbon
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
    private var shiftWasDown = false
    private var shiftUsedWithKey = false
    private var composedPhrase = ""
    private var composedPinyin: [String] = []
    private var hasNavigatedCandidates = false
    private var showingSuggestions = false
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

    private func textClient(from sender: Any?) -> (any IMKTextInput)? {
        if let sender = sender as? any IMKTextInput {
            return sender
        }
        return client()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
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
        guard let event, let client = textClient(from: sender) else {
            logger.error("无法从输入事件取得文本客户端")
            return false
        }
        activeClient = client
        logger.debug("收到输入事件：type=\(event.type.rawValue), keyCode=\(event.keyCode)")
        return safelyHandle(event, client: client)
    }

    /// Some WebKit/Electron text clients fall back to the key-binding delivery path instead
    /// of forwarding NSEvent objects. Supporting this callback keeps those clients usable.
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let string, !string.isEmpty, let client = textClient(from: sender) else { return false }
        activeClient = client

        for character in string {
            if character.isASCII, character.isLetter {
                if raw.isEmpty {
                    composedPhrase = ""
                    composedPinyin = []
                }
                raw.append(String(character).lowercased())
                refresh(client)
                continue
            }
            if character == "'", !raw.isEmpty {
                raw.append(character)
                refresh(client)
                continue
            }
            if character == " " {
                if !raw.isEmpty {
                    commitHighlighted(client)
                } else if showingSuggestions, !output.candidates.isEmpty {
                    commitSuggestion(highlighted, client: client)
                } else {
                    client.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                }
                continue
            }
            if let number = character.wholeNumberValue, (!raw.isEmpty || showingSuggestions) {
                let maximumNumber = expandedCandidates ? 6 : 9
                if (1...maximumNumber).contains(number) {
                    let activeRowStart = expandedCandidates ? highlighted / 6 * 6 : 0
                    if showingSuggestions, raw.isEmpty {
                        commitSuggestion(activeRowStart + number - 1, client: client)
                    } else {
                        selectVisible(activeRowStart + number - 1, client: client)
                    }
                    continue
                }
            }
            if !raw.isEmpty {
                commitHighlighted(client)
                let text = character.isASCII
                    ? localizedPunctuation(for: character)
                    : String(character)
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
                engine.breakPhraseLearningContext()
                clearSuggestions()
            } else {
                client.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            }
        }
        logger.debug("已通过 inputText 回退路径处理输入")
        return true
    }

    /// Some custom text controls (including Electron/WebKit-based clients) request the
    /// IMKServerInput "text data only" delivery mode. In that mode InputMethodKit does not
    /// call handle(_:client:) or inputText(_:client:); it supplies Unicode, hardware key code,
    /// and modifiers through this four-argument callback instead.
    override func inputText(
        _ string: String!,
        key keyCode: Int,
        modifiers flags: Int,
        client sender: Any!
    ) -> Bool {
        guard let string,
              let client = textClient(from: sender),
              (0...Int(UInt16.max)).contains(keyCode) else { return false }
        activeClient = client

        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags))
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: string,
            charactersIgnoringModifiers: string.lowercased(),
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) {
            logger.debug("已通过文本数据回退路径处理输入：keyCode=\(keyCode)")
            return safelyHandle(event, client: client)
        }
        return inputText(string, client: sender)
    }

    override func didCommand(by aSelector: Selector!, client sender: Any!) -> Bool {
        guard let aSelector, let client = textClient(from: sender) else { return false }
        activeClient = client
        switch NSStringFromSelector(aSelector) {
        case "deleteBackward:":
            guard !raw.isEmpty else {
                if showingSuggestions {
                    clearSuggestions()
                    return true
                }
                return false
            }
            raw.removeLast()
            refresh(client)
            return true
        case "cancelOperation:":
            guard !raw.isEmpty || showingSuggestions else { return false }
            reset(client)
            return true
        case "insertNewline:", "insertLineBreak:":
            guard !raw.isEmpty || showingSuggestions else { return false }
            if showingSuggestions, raw.isEmpty {
                commitSuggestion(highlighted, client: client)
            } else if hasNavigatedCandidates {
                commitHighlighted(client)
            } else {
                commit(composedPhrase + raw, pinyin: [], client: client, learn: false)
            }
            return true
        case "moveLeft:":
            return moveHighlight(-1)
        case "moveRight:":
            return moveHighlight(1)
        case "moveDown:":
            return moveDown()
        case "moveUp:":
            return moveUp()
        case "pageUp:":
            return movePage(-1)
        case "pageDown:":
            return movePage(1)
        default:
            return false
        }
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
            if raw.isEmpty {
                if showingSuggestions, !output.candidates.isEmpty {
                    commitSuggestion(highlighted, client: client)
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
            if raw.isEmpty {
                if showingSuggestions {
                    clearSuggestions()
                    return true
                }
                return false
            }
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
        showingSuggestions = false
        let prefs = PreferencesStore.load()
        output = addingEnglishCandidates(to: engine.update(raw, prefs: prefs))
        page = 0
        highlighted = 0
        expandedCandidates = false
        hasNavigatedCandidates = false
        let converted = localized(composedPhrase, prefs: prefs)
        let rawPreedit = output.preedit.isEmpty ? raw : output.preedit
        // Notes / Markdown / Electron clients often ignore plain String marked text.
        // Send an attributed buffer with IMK mark styles, matching Squirrel/落格.
        setMarkedText(converted: converted, rawPreedit: rawPreedit, client: client)
        candidateWindow.update(
            candidates: localizedCandidates(visibleCandidates, prefs: prefs),
            highlighted: highlighted,
            prefs: prefs,
            expanded: expandedCandidates,
            client: client
        )
    }

    /// Builds the inline composition buffer the way InputMethodKit expects.
    /// Plain `String` works in many AppKit clients, but Notes and several
    /// WebKit/Electron editors only honor attributed marked text with TSM hilite styles.
    private func setMarkedText(converted: String, rawPreedit: String, client: IMKTextInput) {
        let marked = converted + rawPreedit
        let attributed = NSMutableAttributedString(string: marked)
        let convertedLength = (converted as NSString).length
        let totalLength = attributed.length

        if convertedLength > 0 {
            let range = NSRange(location: 0, length: convertedLength)
            if let attrs = mark(forStyle: kTSMHiliteConvertedText, at: range) as? [NSAttributedString.Key: Any] {
                attributed.setAttributes(attrs, range: range)
            }
        }
        if convertedLength < totalLength {
            let range = NSRange(location: convertedLength, length: totalLength - convertedLength)
            if let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: range) as? [NSAttributedString.Key: Any] {
                attributed.setAttributes(attrs, range: range)
            }
        }

        client.setMarkedText(
            attributed,
            selectionRange: NSRange(location: totalLength, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func clearMarkedText(client: IMKTextInput) {
        client.setMarkedText(
            NSAttributedString(string: ""),
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
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
            commit(composedPhrase, pinyin: composedPinyin, client: client, learn: false, suggest: !composedPinyin.isEmpty)
        } else {
            refresh(client)
        }
    }

    private func commit(_ text: String, pinyin: [String], client: IMKTextInput, learn: Bool, suggest: Bool = false) {
        let committedText = localized(text, prefs: PreferencesStore.load())
        client.insertText(committedText, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        clearMarkedText(client: client)
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
    }

    private func showSuggestions(_ client: IMKTextInput) {
        let prefs = PreferencesStore.load()
        let suggestions = engine.suggestions(limit: prefs.pageSize)
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
            candidates: localizedCandidates(suggestions, prefs: prefs),
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
        guard showingSuggestions, output.candidates.indices.contains(visibleIndex) else { return }
        let suggestion = output.candidates[visibleIndex]
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
        clearMarkedText(client: client)
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
        if showingSuggestions { return moveHighlight(1) }
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
        guard !raw.isEmpty || showingSuggestions else { return false }
        if showingSuggestions { return moveHighlight(-1) }
        guard expandedCandidates else { return false }
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
                consumedLength: candidate.consumedLength
            )
        }
    }
}
