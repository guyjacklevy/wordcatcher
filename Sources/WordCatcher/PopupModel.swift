import Foundation

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
    enum Phase { case idle, loading, picker, results, error }

    @Published var phase: Phase = .idle
    @Published var marked: [String] = []
    @Published var sentence: String?
    @Published var tokens: [PickToken] = []
    @Published var picked: [Int] = []
    @Published var rows: [ResultRow] = []
    @Published var isSaved = true
    @Published var errorMessage = ""
    @Published var errorAction: ErrorAction?

    var onClose: () -> Void = {}
    var onTranslatePicked: () -> Void = {}
    var onToggleSaved: () -> Void = {}
    var onChangeWords: () -> Void = {}
    var onErrorAction: (ErrorAction) -> Void = { _ in }

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
