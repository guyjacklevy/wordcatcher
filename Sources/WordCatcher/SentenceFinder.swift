import Foundation
import NaturalLanguage

/// Finds the sentence around a selection, using Apple's sentence tokenizer.
enum SentenceFinder {
    /// The sentence in `text` that contains `range` (UTF-16 offsets, as Accessibility reports them).
    static func sentence(in text: String, around range: NSRange) -> String? {
        let ns = text as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= ns.length else { return nil }

        // Only look at a window around the selection, so huge documents stay fast.
        let windowStart = max(0, range.location - 800)
        let windowEnd = min(ns.length, NSMaxRange(range) + 800)
        let window = ns.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))
        let local = NSRange(location: range.location - windowStart, length: range.length)
        guard let target = Range(local, in: window) else { return nil }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = window
        var lower: String.Index?
        var upper: String.Index?
        tokenizer.enumerateTokens(in: window.startIndex..<window.endIndex) { tokenRange, _ in
            if lower == nil, tokenRange.upperBound > target.lowerBound { lower = tokenRange.lowerBound }
            if tokenRange.upperBound >= target.upperBound {
                upper = tokenRange.upperBound
                return false
            }
            return true
        }
        guard let lower, let upper, lower < upper else { return nil }
        return clean(String(window[lower..<upper]))
    }

    /// The sentence in `text` that contains the first occurrence of `phrase`.
    static func sentence(in text: String, containing phrase: String) -> String? {
        guard let found = text.range(of: phrase) else { return nil }
        return sentence(in: text, around: NSRange(found, in: text))
    }

    /// Collapses line breaks and repeated spaces; caps very long "sentences".
    static func clean(_ text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 600 ? String(collapsed.prefix(600)) : collapsed
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var wordCount: Int { split(whereSeparator: { $0.isWhitespace }).count }
}
