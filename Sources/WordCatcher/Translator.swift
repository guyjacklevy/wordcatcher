import Foundation

/// Claude's explanation of one marked word or phrase, as used in its sentence.
struct WordInfo: Codable, Hashable {
    let marked: String
    let lemma: String
    let partOfSpeech: String
    let ipa: String
    let hebrew: String
    let meaning: String
    let meaningHere: String
    let example: String

    enum CodingKeys: String, CodingKey {
        case marked, lemma, ipa, hebrew, meaning, example
        case partOfSpeech = "part_of_speech"
        case meaningHere = "meaning_here"
    }

    /// "To make a risk smaller. Here: reduce the main risks before launch."
    var meaningInContext: String {
        meaningHere.trimmed.isEmpty ? meaning : "\(meaning) Here: \(meaningHere)"
    }
}

/// One English option for a Hebrew word the user wrote.
struct ComposeChoice: Codable, Hashable {
    let word: String    // dictionary form: "submit"
    let fitted: String  // the exact form for this sentence: "submitted"
    let note: String    // when to use it: "best fit here", "more casual"
    let ipa: String
    let meaning: String
    let example: String
}

/// A Hebrew word or phrase inside the user's English, with its English options (best first).
struct ComposeItem: Codable, Hashable {
    let hebrew: String
    let partOfSpeech: String
    let choices: [ComposeChoice]

    enum CodingKeys: String, CodingKey {
        case hebrew, choices
        case partOfSpeech = "part_of_speech"
    }
}

/// The selected text in English, with {0}, {1}… where each item's English goes.
struct ComposeResult: Codable {
    let template: String
    let items: [ComposeItem]
}

enum TranslatorError: LocalizedError {
    case missingKey
    case http(status: Int, message: String)
    case refused
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add your Claude API key first. It's in the Word Catcher menu (the book icon in the menu bar)."
        case .http(let status, let message):
            if status == 401 { return "Claude didn't accept the API key. Check it in the Word Catcher menu." }
            return "Claude returned an error (\(status)): \(message)"
        case .refused:
            return "Claude declined to explain this text."
        case .unreadable:
            return "Claude's answer couldn't be read. Try again."
        }
    }
}

/// Calls the Claude Messages API directly over HTTPS. Swift has no official Anthropic SDK.
enum Translator {
    static let model = "claude-haiku-4-5"

    // MARK: - Reading: explain an English word

    static func explain(marked: [String], sentence: String?) async throws -> [WordInfo] {
        let context = sentence.map { "Sentence: \"\($0)\"" } ?? "Sentence: (not available)"
        let user: String
        if marked.count == 1 {
            user = "\(context)\nMarked: \"\(marked[0])\""
        } else {
            let list = marked.enumerated().map { "\($0.offset + 1). \"\($0.element)\"" }.joined(separator: "\n")
            user = "\(context)\nMarked (explain each one, in this order):\n\(list)"
        }

        struct Payload: Decodable { let items: [WordInfo] }
        let payload: Payload = try await ask(system: explainPrompt, user: user, schema: explainSchema)
        guard !payload.items.isEmpty else { throw TranslatorError.unreadable }
        return payload.items
    }

    private static let explainPrompt = """
    You help a native Hebrew speaker who reads English at work learn new vocabulary. \
    They marked a word or phrase in something they were reading. For each marked item, \
    explain it as it is used in that sentence, in simple English a learner understands.

    Fields:
    - marked: the marked text, exactly as given.
    - lemma: the dictionary form ("streamlined" → "streamline"). If the marked text is part of \
    a multi-word expression in this sentence (phrasal verb, idiom, fixed phrase), use the whole \
    expression ("roll this out" → "roll out").
    - part_of_speech: noun, verb, adjective, adverb, phrase, or idiom.
    - ipa: American pronunciation in IPA, between slashes.
    - hebrew: one or two short Hebrew translations that fit this sentence, separated by " · ", without niqqud.
    - meaning: a short, simple English definition, at most 12 words.
    - meaning_here: what it means in this specific sentence, at most 12 words. Empty string if no sentence was given.
    - example: one new, natural example sentence from a work setting.
    """

    private static let explainSchema: [String: Any] = object([
        "items": array(of: object([
            "marked": string, "lemma": string, "part_of_speech": string, "ipa": string,
            "hebrew": string, "meaning": string, "meaning_here": string, "example": string,
        ])),
    ])

    // MARK: - Writing: find the English for Hebrew inside an English sentence

    static func compose(text: String, sentence: String?) async throws -> ComposeResult {
        var user = "Text: \"\(text)\""
        if let sentence, sentence != text { user += "\nThe sentence it's in: \"\(sentence)\"" }

        let result: ComposeResult = try await ask(system: composePrompt, user: user, schema: composeSchema)
        let usable = result.items.filter { !$0.choices.isEmpty }
        guard !result.template.trimmed.isEmpty || !usable.isEmpty else { throw TranslatorError.unreadable }
        return ComposeResult(template: result.template, items: usable)
    }

    private static let composePrompt = """
    You help a native Hebrew speaker write in English at work. When they don't know an English word, \
    they write it in Hebrew inside their English sentence, or write a whole sentence in Hebrew. \
    Find the English that fits their exact sentence: the right meaning, the right tone, and correct \
    grammar (tense, plural, articles, prepositions).

    Fields:
    - template: the Text rewritten in natural English, with {0}, {1}, … standing exactly where each item's \
    English goes. Keep the user's own English words and style; change only what the replaced words require \
    (for example an article or a preposition next to them). If the Text is only the Hebrew word or words, \
    the template is just "{0}" (or "{0} {1}" and so on), using the surrounding sentence to choose the meaning and form.
    - items: one per Hebrew word or phrase, in the order they appear. If the Text is entirely or mostly Hebrew, translate \
    it into the template and make items for the 1 to 3 words or expressions most worth learning.
      - hebrew: the Hebrew exactly as it appears in the Text.
      - part_of_speech: noun, verb, adjective, adverb, phrase, or idiom.
      - choices: 1 to 3 English options, best first. Offer more than one only when another option is \
    genuinely good, with a different tone or nuance.
        - word: the dictionary form ("submit").
        - fitted: the exact form that goes into this sentence ("submitted"), including any article that must change with it.
        - note: when to use it, at most 5 words ("best fit here", "more casual", "formal, for documents").
        - ipa: American pronunciation of the word, in IPA between slashes.
        - meaning: a short, simple English definition, at most 12 words.
        - example: one new, natural example sentence from a work setting.
    """

    private static let composeSchema: [String: Any] = object([
        "template": string,
        "items": array(of: object([
            "hebrew": string,
            "part_of_speech": string,
            "choices": array(of: object([
                "word": string, "fitted": string, "note": string, "ipa": string, "meaning": string, "example": string,
            ])),
        ])),
    ])

    // MARK: - Reading: a whole English sentence in Hebrew

    static func translateToHebrew(_ text: String) async throws -> String {
        struct Payload: Decodable { let translation: String }
        let payload: Payload = try await ask(system: hebrewPrompt, user: "Text: \"\(text)\"", schema: object(["translation": string]))
        guard !payload.translation.trimmed.isEmpty else { throw TranslatorError.unreadable }
        return payload.translation
    }

    private static let hebrewPrompt = """
    Translate the Text into natural, fluent Hebrew, the way an Israeli professional would say it. \
    Keep the meaning and tone exactly; don't add or drop anything. Keep names, products and code in English. \
    Write without niqqud. translation: the Hebrew translation only.
    """

    // MARK: - HTTP

    private static func ask<T: Decodable>(system: String, user: String, schema: [String: Any]) async throws -> T {
        guard let key = Keychain.apiKey() else { throw TranslatorError.missingKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TranslatorError.http(status: status, message: apiErrorMessage(data)) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslatorError.unreadable
        }
        if json["stop_reason"] as? String == "refusal" { throw TranslatorError.refused }

        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let payload = text.data(using: .utf8) else { throw TranslatorError.unreadable }
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw TranslatorError.unreadable
        }
    }

    private static func apiErrorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }

    // Small JSON-schema builders. Structured outputs need every field required and no extra fields.
    private static let string: [String: Any] = ["type": "string"]

    private static func object(_ properties: [String: [String: Any]]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys), "additionalProperties": false]
    }

    private static func array(of items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }
}

extension String {
    /// True when the text contains Hebrew letters.
    var containsHebrew: Bool { range(of: "[\\u0590-\\u05FF]", options: .regularExpression) != nil }

    /// True when Hebrew letters outnumber Latin ones: a Hebrew sentence, maybe with an English term in it.
    var isMostlyHebrew: Bool {
        var hebrew = 0
        var latin = 0
        for scalar in unicodeScalars {
            if (0x05D0...0x05EA).contains(scalar.value) {
                hebrew += 1
            } else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                latin += 1
            }
        }
        return hebrew > 0 && hebrew >= latin
    }
}
