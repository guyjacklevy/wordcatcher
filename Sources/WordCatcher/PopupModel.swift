import Foundation
import SwiftUI

struct PickToken: Identifiable, Hashable {
    let id: Int
    let text: String   // as shown, with punctuation: "ambiguous,"
    let word: String?  // what gets sent to Claude: "ambiguous"; nil for tokens with no letters
}

struct ResultRow: Identifiable {
    let id = UUID()
    let info: WordInfo
    var outcome: SaveOutcome
}

enum ErrorAction {
    case apiKey
    case accessibility
}

/// Everything the popup shows. The controller changes it; the SwiftUI view draws it.
@MainActor
final class PopupModel: ObservableObject {
    enum Phase { case idle, loading, picker, results, compose, polish, error }

    @Published var phase: Phase = .idle
    @Published var marked: [String] = []
    @Published var sentence: String?
    @Published var tokens: [PickToken] = []
    @Published var picked: [Int] = []
    @Published var rows: [ResultRow] = []
    @Published var isSaved = true
    @Published var errorMessage = ""
    @Published var errorAction: ErrorAction?
    @Published var loadingText = "Translating…"
    /// True while helping you write (Hebrew → English), false while explaining something you read.
    @Published var writing = false

    // Writing helper: English with Hebrew in it → the right English.
    @Published var composeTemplate = ""
    @Published var composeItems: [ComposeItem] = []
    @Published var composeChoice: [Int] = []
    @Published var composeSelection = ""
    @Published var composeContext: String?
    @Published var composeNote = ""
    @Published var copied = false
    /// A whole Hebrew sentence → English: words are offered for saving, not saved automatically.
    @Published var wholeTranslation = false

    // A whole English sentence → Hebrew, shown above the word picker.
    @Published var sentenceTranslation: String?
    @Published var translatingSentence = false
    @Published var translationCopied = false

    // Improve my English.
    @Published var polishOriginal = ""
    @Published var polishResult: PolishResult?
    @Published var polishStyle: String?
    @Published var polishing = false
    /// English sentences can be read (translate) or your own writing (improve); the card offers the other one.
    @Published var canSwitchMode = false

    // Footer wording while nothing is saved.
    @Published var unsavedNote = "Removed. It's not in your words."
    @Published var saveLabel = "Save it"

    var onClose: () -> Void = {}
    var onTranslatePicked: () -> Void = {}
    var onToggleSaved: () -> Void = {}
    var onChangeWords: () -> Void = {}
    var onErrorAction: (ErrorAction) -> Void = { _ in }
    var onChoose: (Int, Int) -> Void = { _, _ in }
    var onUseIt: () -> Void = {}
    var onCopy: () -> Void = {}
    var onCopyTranslation: () -> Void = {}
    var onPolishStyle: (String?) -> Void = { _ in }
    var onSwitchToPolish: () -> Void = {}
    var onSwitchToTranslate: () -> Void = {}

    /// The improved text, with the words that changed marked.
    var polishedText: AttributedString {
        Self.highlightChanges(from: polishOriginal, to: polishResult?.improved ?? "")
    }

    /// Marks the words in `new` that aren't in `old` (a word-level longest-common-subsequence diff).
    nonisolated static func highlightChanges(from old: String, to new: String) -> AttributedString {
        func words(_ text: String) -> [(range: Range<String.Index>, key: String)] {
            var found: [(Range<String.Index>, String)] = []
            var start = text.startIndex
            while start < text.endIndex {
                if text[start].isWhitespace { start = text.index(after: start); continue }
                var end = start
                while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
                found.append((start..<end, text[start..<end].lowercased()))
                start = end
            }
            return found
        }
        let a = words(old).map(\.key)
        let bWords = words(new)
        let b = bWords.map(\.key)
        guard a.count * b.count < 400_000 else { return AttributedString(new) } // very long text: no marks

        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var kept = Set<Int>()
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                kept.insert(j)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        var result = AttributedString()
        var cursor = new.startIndex
        for (index, word) in bWords.enumerated() {
            result.append(AttributedString(String(new[cursor..<word.range.lowerBound])))
            var piece = AttributedString(String(new[word.range]))
            if !kept.contains(index) { piece.backgroundColor = .marker }
            result.append(piece)
            cursor = word.range.upperBound
        }
        result.append(AttributedString(String(new[cursor...])))
        return result
    }

    func chosen(_ item: Int) -> ComposeChoice? {
        guard composeItems.indices.contains(item) else { return nil }
        let choices = composeItems[item].choices
        let index = composeChoice.indices.contains(item) ? composeChoice[item] : 0
        return choices.indices.contains(index) ? choices[index] : choices.first
    }

    /// The template split into plain text and the slots where each item's English goes.
    private var templateParts: [(text: String, item: Int?)] {
        var parts: [(String, Int?)] = []
        var rest = Substring(composeTemplate)
        while let open = rest.range(of: "{"), let close = rest[open.upperBound...].range(of: "}"),
              let index = Int(rest[open.upperBound..<close.lowerBound]), composeItems.indices.contains(index) {
            parts.append((String(rest[..<open.lowerBound]), nil))
            parts.append((chosen(index)?.fitted ?? "", index))
            rest = rest[close.upperBound...]
        }
        parts.append((String(rest), nil))
        return parts
    }

    /// What replaces the selection in the user's app.
    var composedText: String {
        let text = templateParts.map(\.text).joined()
        return text.trimmed.isEmpty ? composeItems.indices.compactMap { chosen($0)?.fitted }.joined(separator: " ") : text
    }

    /// The whole sentence as it will read, with the new English words marked.
    var composedSentence: AttributedString {
        var result = AttributedString()
        let (before, after) = surroundings
        result.append(AttributedString(before))
        for part in templateParts {
            var piece = AttributedString(part.text)
            if part.item != nil { piece.backgroundColor = .marker }
            result.append(piece)
        }
        result.append(AttributedString(after))
        return result
    }

    /// The same sentence as plain text (saved with each word).
    var composedSentencePlain: String {
        let (before, after) = surroundings
        return before + composedText + after
    }

    /// The parts of the sentence before and after the selection, when the selection was only part of it.
    private var surroundings: (String, String) {
        guard let context = composeContext, context != composeSelection,
              let range = context.range(of: composeSelection) else { return ("", "") }
        return (String(context[..<range.lowerBound]), String(context[range.upperBound...]))
    }

    /// True when the result came from the "select a sentence, pick words" flow.
    var canChangeWords: Bool { !tokens.isEmpty }

    func togglePick(_ token: PickToken) {
        if let index = picked.firstIndex(of: token.id) {
            picked.remove(at: index)
        } else {
            picked.append(token.id)
        }
    }

    /// Picked words in sentence order, without duplicates.
    var pickedWords: [String] {
        var seen = Set<String>()
        return tokens
            .filter { picked.contains($0.id) }
            .compactMap(\.word)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    static func tokenize(_ sentence: String) -> [PickToken] {
        sentence
            .split(whereSeparator: { $0.isWhitespace })
            .enumerated()
            .map { index, piece in
                let text = String(piece)
                let word = text.trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: "'’-")))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
                return PickToken(id: index, text: text, word: word.rangeOfCharacter(from: .letters) == nil ? nil : word)
            }
    }
}
