import AppKit
import SwiftUI

/// A floating panel that doesn't take focus away from the app you're reading in.
final class PopupPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 416, height: 300),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // SwiftUI draws the shadow
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    // Becomes key only when clicked, so buttons work; it never activates the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a button in the panel count, even before the panel is key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PopupController {
    private let store: WordStore
    private let model = PopupModel()
    private var panel: PopupPanel?
    private var hostingView: FirstClickHostingView<PopupView>?
    private var anchorTopLeft = NSPoint.zero
    private var capture: Capture?
    private var translateTask: Task<Void, Never>?
    private var closeTimer: Timer?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?

    var openAPIKeySettings: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}

    init(store: WordStore) {
        self.store = store
        model.onClose = { [weak self] in self?.close() }
        model.onTranslatePicked = { [weak self] in self?.translatePicked() }
        model.onToggleSaved = { [weak self] in self?.toggleSaved() }
        model.onChangeWords = { [weak self] in self?.backToPicker() }
        model.onChoose = { [weak self] item, choice in self?.choose(item: item, choice: choice) }
        model.onUseIt = { [weak self] in self?.useComposed() }
        model.onCopy = { [weak self] in self?.copyComposed() }
        model.onCopyTranslation = { [weak self] in self?.copySentenceTranslation() }
        model.onPolishStyle = { [weak self] style in self?.restyle(style) }
        model.onSwitchToPolish = { [weak self] in self?.startPolish() }
        model.onSwitchToTranslate = { [weak self] in self?.startReading() }
        model.onErrorAction = { [weak self] action in
            self?.close()
            switch action {
            case .apiKey: self?.openAPIKeySettings()
            case .accessibility: self?.openAccessibilitySettings()
            }
        }
    }

    // MARK: - Entry points

    func start(capture: Capture, at point: NSPoint) {
        self.capture = capture
        model.tokens = []
        model.picked = []
        model.writing = false
        model.loadingText = "Translating…"
        model.sentenceTranslation = nil
        model.translatingSentence = false
        model.translationCopied = false
        model.wholeTranslation = false
        model.unsavedNote = "Removed. It's not in your words."
        model.saveLabel = "Save it"
        model.canSwitchMode = false
        model.polishResult = nil
        model.polishStyle = nil
        model.polishing = false
        sentenceTask?.cancel()

        if capture.selection.containsHebrew {
            // Writing: Hebrew inside English → the English that fits.
            // A Hebrew sentence → the whole sentence in English.
            show(at: point)
            compose(text: capture.selection, sentence: capture.sentence, whole: capture.selection.isMostlyHebrew)
        } else if capture.selection.wordCount > 4 {
            // A whole English sentence: your own writing gets improved, anything else gets translated.
            model.canSwitchMode = true
            show(at: point)
            if capture.editable { startPolish() } else { startReading() }
        } else {
            show(at: point)
            translate(marked: [capture.selection], sentence: capture.sentence)
        }
    }

    func showError(_ message: String, action: ErrorAction?, at point: NSPoint) {
        model.errorMessage = message
        model.errorAction = action
        setPhase(.error)
        show(at: point)
    }

    // MARK: - Flow

    private func translate(marked: [String], sentence: String?) {
        model.marked = marked
        model.sentence = sentence
        setPhase(.loading)

        translateTask?.cancel()
        translateTask = Task { [weak self] in
            do {
                let infos = try await Translator.explain(marked: marked, sentence: sentence)
                guard let self, !Task.isCancelled else { return }
                let app = self.capture?.appName ?? ""
                self.model.rows = infos.map { ResultRow(info: $0, outcome: self.store.save($0, sentence: sentence, app: app)) }
                self.model.isSaved = true
                self.setPhase(.results)
                self.scheduleAutoClose()
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.write("translate error: \(error.localizedDescription)")
                self.model.errorMessage = error.localizedDescription
                self.model.errorAction = (error as? TranslatorError).flatMap { if case .missingKey = $0 { return .apiKey } else { return nil } }
                self.setPhase(.error)
            }
        }
    }

    // MARK: - Reading an English sentence: Hebrew translation + word picker

    private func startReading() {
        guard let capture else { return }
        translateTask?.cancel()
        model.polishing = false
        model.sentence = SentenceFinder.clean(capture.selection) ?? capture.selection
        model.tokens = PopupModel.tokenize(model.sentence ?? "")
        model.picked = []
        setPhase(.picker)
        if model.sentenceTranslation == nil, !model.translatingSentence {
            translateSentence(model.sentence ?? capture.selection)
        }
    }

    // MARK: - Improve my English

    private func startPolish() {
        guard let capture else { return }
        model.polishOriginal = capture.selection
        model.polishStyle = nil
        model.copied = false
        Log.write("polish app=\(capture.app?.bundleIdentifier ?? "?") editable=\(capture.editable)")
        runPolish()
    }

    private func restyle(_ style: String?) {
        model.polishStyle = style
        model.copied = false
        runPolish()
    }

    private func runPolish() {
        let original = model.polishOriginal
        let style = model.polishStyle
        model.polishing = true
        setPhase(.polish)

        translateTask?.cancel()
        translateTask = Task { [weak self] in
            do {
                let result = try await Translator.polish(original, style: style)
                guard let self, !Task.isCancelled else { return }
                self.model.polishResult = result
                self.model.polishing = false
                self.refitSoon()
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.write("polish error: \(error.localizedDescription)")
                self.model.polishing = false
                self.model.errorMessage = error.localizedDescription
                self.model.errorAction = (error as? TranslatorError).flatMap { if case .missingKey = $0 { return .apiKey } else { return nil } }
                self.setPhase(.error)
            }
        }
    }

    // MARK: - Sentence translation (English → Hebrew)

    private var sentenceTask: Task<Void, Never>?

    /// Runs alongside the word picker, so tapping words never waits for it.
    private func translateSentence(_ text: String) {
        model.translatingSentence = true
        sentenceTask = Task { [weak self] in
            let translation = try? await Translator.translateToHebrew(text)
            guard let self, !Task.isCancelled else { return }
            self.model.sentenceTranslation = translation
            self.model.translatingSentence = false
            self.refitSoon()
        }
    }

    private func copySentenceTranslation() {
        guard let translation = model.sentenceTranslation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translation, forType: .string)
        model.translationCopied = true
    }

    // MARK: - Writing helper

    private var composeOutcomes: [Int: SaveOutcome] = [:]

    private func compose(text: String, sentence: String?, whole: Bool = false) {
        model.writing = true
        model.wholeTranslation = whole
        model.loadingText = whole ? "Translating into English…" : "Finding the English…"
        model.marked = [text]
        model.sentence = sentence
        model.composeSelection = text
        model.composeContext = sentence
        model.copied = false
        composeOutcomes = [:]
        setPhase(.loading)

        translateTask?.cancel()
        translateTask = Task { [weak self] in
            do {
                let result = try await Translator.compose(text: text, sentence: sentence)
                guard let self, !Task.isCancelled else { return }
                self.model.composeTemplate = result.template
                self.model.composeItems = result.items
                self.model.composeChoice = result.items.map { _ in 0 }
                if whole {
                    // A translation: offer the words, don't fill the list with them.
                    self.model.isSaved = false
                    self.model.unsavedNote = result.items.count == 1 ? "Want to practice this word?" : "Want to practice these words?"
                    self.model.saveLabel = result.items.count == 1 ? "Save it" : "Save them"
                } else {
                    for index in result.items.indices { self.saveComposed(item: index) }
                    self.model.isSaved = true
                    self.model.unsavedNote = "Removed. It's not in your words."
                    self.model.saveLabel = "Save it"
                }
                self.updateComposeNote()
                self.setPhase(.compose)
                Log.write("compose items=\(result.items.count) app=\(self.capture?.app?.bundleIdentifier ?? "?")")
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.write("compose error: \(error.localizedDescription)")
                self.model.errorMessage = error.localizedDescription
                self.model.errorAction = (error as? TranslatorError).flatMap { if case .missingKey = $0 { return .apiKey } else { return nil } }
                self.setPhase(.error)
            }
        }
    }

    /// Saves the chosen English for one Hebrew word, to be practiced in reverse on the phone.
    private func saveComposed(item index: Int) {
        guard let choice = model.chosen(index) else { return }
        let item = model.composeItems[index]
        let info = WordInfo(
            marked: choice.fitted, lemma: choice.word, partOfSpeech: item.partOfSpeech, ipa: choice.ipa,
            hebrew: item.hebrew, meaning: choice.meaning, meaningHere: choice.note, example: choice.example
        )
        composeOutcomes[index] = store.save(
            info, sentence: model.composedSentencePlain, app: capture?.appName ?? "",
            direction: "write", sourceText: model.composeContext ?? model.composeSelection, sourceMarked: item.hebrew
        )
    }

    private func choose(item: Int, choice: Int) {
        guard model.composeChoice.indices.contains(item), model.composeChoice[item] != choice else { return }
        if model.isSaved, let previous = composeOutcomes[item] { store.undo(previous, sentence: model.composedSentencePlain) }
        model.composeChoice[item] = choice
        model.copied = false
        if model.isSaved { saveComposed(item: item) }
        updateComposeNote()
        refitSoon()
    }

    private func updateComposeNote() {
        let added = composeOutcomes.values.filter { $0.kind == .added }.count
        model.composeNote = added > 0
            ? "Saved to your words · you'll practice saying it"
            : "Already in your words · you'll practice saying it"
    }

    /// The text "Use it" and "Copy" act on: the improved English, or the English for your Hebrew.
    private var outputText: String {
        model.phase == .polish ? (model.polishResult?.improved ?? "") : model.composedText
    }

    private func useComposed() {
        let text = outputText
        guard !text.isEmpty else { return }
        let app = capture?.app
        Log.write("\(model.phase == .polish ? "polish" : "compose") used app=\(app?.bundleIdentifier ?? "?")")
        closeTimer?.invalidate()
        removeMonitors()
        panel?.orderOut(nil) // give the keyboard back to your app before pasting
        model.phase = .idle
        Task { await SelectionReader.replaceSelection(with: text, in: app) }
    }

    private func copyComposed() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
        model.copied = true
        scheduleAutoClose()
    }

    private func refitSoon() {
        DispatchQueue.main.async { [weak self] in self?.refit() }
    }

    private func translatePicked() {
        let words = model.pickedWords
        guard !words.isEmpty else { return }
        translate(marked: words, sentence: model.sentence)
    }

    private func backToPicker() {
        closeTimer?.invalidate()
        setPhase(.picker)
    }

    private func toggleSaved() {
        if model.phase == .compose {
            if model.isSaved {
                for outcome in composeOutcomes.values { store.undo(outcome, sentence: model.composedSentencePlain) }
                composeOutcomes = [:]
                model.isSaved = false
                model.unsavedNote = "Removed. It's not in your words."
                model.saveLabel = model.composeItems.count == 1 ? "Save it" : "Save them"
            } else {
                for index in model.composeItems.indices { saveComposed(item: index) }
                model.isSaved = true
                updateComposeNote()
            }
            return
        }
        if model.isSaved {
            for row in model.rows { store.undo(row.outcome, sentence: model.sentence) }
            model.isSaved = false
            closeTimer?.invalidate()
        } else {
            let app = capture?.appName ?? ""
            model.rows = model.rows.map { row in
                var updated = row
                updated.outcome = store.save(row.info, sentence: model.sentence, app: app)
                return updated
            }
            model.isSaved = true
            scheduleAutoClose()
        }
    }

    // MARK: - Panel

    private func setPhase(_ phase: PopupModel.Phase) {
        model.phase = phase
        DispatchQueue.main.async { [weak self] in self?.refit() }
    }

    private func show(at point: NSPoint) {
        if panel == nil {
            let panel = PopupPanel()
            let host = FirstClickHostingView(rootView: PopupView(model: model))
            panel.contentView = host
            self.panel = panel
            self.hostingView = host
        }
        guard let panel, let hostingView else { return }

        let size = hostingView.fittingSize
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // The card sits just below and slightly left of the pointer (the panel has transparent padding).
        var x = point.x - 44
        var top = point.y - 6
        if top - 320 < visible.minY { top = point.y + 320 } // not enough room below: open above
        x = min(max(x, visible.minX), visible.maxX - size.width)
        top = min(top, visible.maxY)
        anchorTopLeft = NSPoint(x: x, y: top)

        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        installMonitors()
        refit()
    }

    private func refit() {
        guard let panel, let hostingView, panel.isVisible else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        panel.setFrame(NSRect(x: anchorTopLeft.x, y: anchorTopLeft.y - size.height, width: size.width, height: size.height), display: true)
    }

    func close() {
        translateTask?.cancel()
        sentenceTask?.cancel()
        closeTimer?.invalidate()
        removeMonitors()
        panel?.orderOut(nil)
        model.phase = .idle
    }

    /// Results disappear on their own after a while, unless the pointer is over them.
    private func scheduleAutoClose() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                    self.scheduleAutoClose()
                } else {
                    self.close()
                }
            }
        }
    }

    /// Click anywhere else, or press Esc, to dismiss.
    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Esc
            Task { @MainActor in self?.close() }
        }
        // After a click the panel is key, so Esc arrives here instead.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in self?.close() }
            return nil
        }
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        mouseMonitor = nil
        keyMonitor = nil
        localKeyMonitor = nil
    }
}
