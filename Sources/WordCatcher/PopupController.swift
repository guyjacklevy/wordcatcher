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

        if capture.selection.wordCount > 4 {
            // A whole sentence was selected: let the user tap the words they don't know.
            model.sentence = SentenceFinder.clean(capture.selection) ?? capture.selection
            model.tokens = PopupModel.tokenize(model.sentence ?? "")
            setPhase(.picker)
            show(at: point)
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
