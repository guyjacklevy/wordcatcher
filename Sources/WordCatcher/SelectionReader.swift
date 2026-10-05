import AppKit
import ApplicationServices
import Carbon

/// What the user selected, plus the sentence around it when the app lets us read it.
struct Capture {
    let selection: String
    let sentence: String?
    let appName: String
}

/// Reads the current selection in the frontmost app.
/// Order: Accessibility text (native apps) → Accessibility text markers (web pages, Electron)
/// → copy with ⌘C as a last resort (no sentence then).
@MainActor
enum SelectionReader {
    static func read() async -> Capture? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = app.localizedName ?? "Unknown app"
        let bundleID = app.bundleIdentifier ?? "unknown"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)

        // Electron apps (Claude, Slack, VS Code…) only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let found = fromAccessibility(axApp) {
            Log.write("capture app=\(bundleID) method=\(found.method) sentence=\(found.sentence != nil)")
            return Capture(selection: found.selection, sentence: found.sentence, appName: appName)
        }

        // The tree may need a moment right after we switched it on.
        try? await Task.sleep(nanoseconds: 150_000_000)
        if let found = fromAccessibility(axApp) {
            Log.write("capture app=\(bundleID) method=\(found.method)-retry sentence=\(found.sentence != nil)")
            return Capture(selection: found.selection, sentence: found.sentence, appName: appName)
        }

        if let copied = await copySelectionViaClipboard() {
            Log.write("capture app=\(bundleID) method=clipboard sentence=false")
            return Capture(selection: copied, sentence: nil, appName: appName)
        }

        Log.write("capture app=\(bundleID) method=none")
        return nil
    }

    // MARK: - Accessibility

    private struct Found {
        let selection: String
        let sentence: String?
        let method: String
    }

    private static func fromAccessibility(_ axApp: AXUIElement) -> Found? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = element(axApp, kAXFocusedUIElementAttribute)
            ?? element(systemWide, kAXFocusedUIElementAttribute) else { return nil }

        // 1. Native text views and fields: selected text + full text + selection range.
        if let selected = string(focused, kAXSelectedTextAttribute), !selected.trimmed.isEmpty {
            var sentence: String?
            var method = "ax-text"
            if let full = string(focused, kAXValueAttribute),
               let range = cfRange(focused, kAXSelectedTextRangeAttribute) {
                sentence = usable(SentenceFinder.sentence(in: full, around: NSRange(location: range.location, length: range.length)), for: selected)
            }
            // Web views (Claude, Slack, browsers) report the selection but not the text around it.
            if sentence == nil, let context = markerContext(startingAt: focused, selected: selected) {
                sentence = context.sentence
                method += "+" + context.method
            }
            return Found(selection: selected.trimmed, sentence: sentence, method: method)
        }

        // 2. Web content: walk up from the focused element until one answers text-marker queries.
        var current: AXUIElement? = focused
        for _ in 0..<12 {
            guard let element = current else { break }
            if let markerRange = attr(element, "AXSelectedTextMarkerRange"),
               let selected = paramString(element, "AXStringForTextMarkerRange", markerRange),
               !selected.trimmed.isEmpty {
                let context = markerContext(on: element, markerRange: markerRange, selected: selected)
                return Found(selection: selected.trimmed, sentence: context?.sentence, method: "ax-marker" + (context.map { "+" + $0.method } ?? ""))
            }
            current = self.element(element, kAXParentAttribute)
        }
        return nil
    }

    /// Walks up to the first element that knows the selection as text markers, then reads the sentence around it.
    private static func markerContext(startingAt element: AXUIElement, selected: String) -> (sentence: String, method: String)? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let element = current else { break }
            if let markerRange = attr(element, "AXSelectedTextMarkerRange") {
                return markerContext(on: element, markerRange: markerRange, selected: selected)
            }
            current = self.element(element, kAXParentAttribute)
        }
        return nil
    }

    private static func markerContext(on element: AXUIElement, markerRange: CFTypeRef, selected: String) -> (sentence: String, method: String)? {
        guard let start = param(element, "AXStartTextMarkerForTextMarkerRange", markerRange) else { return nil }
        let phrase = selected.trimmed

        if let range = param(element, "AXSentenceTextMarkerRangeForTextMarker", start),
           let text = paramString(element, "AXStringForTextMarkerRange", range),
           let sentence = usable(SentenceFinder.clean(text), for: selected) {
            return (sentence, "sentence")
        }
        if let range = param(element, "AXParagraphTextMarkerRangeForTextMarker", start),
           let text = paramString(element, "AXStringForTextMarkerRange", range),
           let sentence = usable(SentenceFinder.sentence(in: text, containing: phrase), for: selected) {
            return (sentence, "paragraph")
        }
        // Last try: the text node that holds the selection, then the blocks around it.
        if let node = param(element, "AXUIElementForTextMarker", start), CFGetTypeID(node) == AXUIElementGetTypeID() {
            var current: AXUIElement? = (node as! AXUIElement)
            for _ in 0..<5 {
                guard let element = current else { break }
                if let sentence = usable(SentenceFinder.sentence(in: visibleText(of: element), containing: phrase), for: selected) {
                    return (sentence, "tree")
                }
                current = self.element(element, kAXParentAttribute)
            }
        }
        return nil
    }

    /// The text of an element's subtree, the way a screen reader sees it. Blocks end with a line break.
    private static func visibleText(of root: AXUIElement) -> String {
        var budget = 400
        var text = ""
        func walk(_ element: AXUIElement) {
            guard budget > 0 else { return }
            budget -= 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXStaticText" {
                text += string(element, kAXValueAttribute) ?? ""
                return
            }
            for child in (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child) }
            if ["AXGroup", "AXParagraph", "AXHeading", "AXListItem", "AXCell"].contains(role), !text.hasSuffix("\n") {
                text += "\n"
            }
        }
        walk(root)
        return text
    }

    /// A sentence is only useful if it actually contains the selection and adds something to it.
    private static func usable(_ sentence: String?, for selection: String) -> String? {
        guard let sentence else { return nil }
        let selected = SentenceFinder.clean(selection) ?? selection
        guard sentence.count > selected.count, sentence.range(of: selected, options: .caseInsensitive) != nil else { return nil }
        return sentence
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func param(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attr(element, name) as? String
    }

    private static func paramString(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> String? {
        param(element, name, parameter) as? String
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attr(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func cfRange(_ element: AXUIElement, _ name: String) -> CFRange? {
        guard let value = attr(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    // MARK: - Clipboard fallback

    private static func copySelectionViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let before = pasteboard.changeCount

        await waitForShortcutRelease()
        postCommandC()

        var copied: String?
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before { restorePasteboard(pasteboard, saved) }

        guard let text = copied?.trimmed, !text.isEmpty else { return nil }
        return text
    }

    /// ⌃⌥ are still held right after the shortcut; wait so ⌘C isn't sent as ⌃⌥⌘C.
    private static func waitForShortcutRelease() async {
        for _ in 0..<25 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskControl), !flags.contains(.maskAlternate), !flags.contains(.maskShift) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        let items = saved.map { copy -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in copy { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
