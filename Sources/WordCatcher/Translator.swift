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

    static func explain(marked: [String], sentence: String?) async throws -> [WordInfo] {
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
            "output_config": [
                "format": ["type": "json_schema", "schema": schema],
            ],
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage(marked: marked, sentence: sentence)]],
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

        struct Payload: Decodable { let items: [WordInfo] }
        let items = try JSONDecoder().decode(Payload.self, from: payload).items
        guard !items.isEmpty else { throw TranslatorError.unreadable }
        return items
    }

    private static let systemPrompt = """
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

    private static func userMessage(marked: [String], sentence: String?) -> String {
        let context = sentence.map { "Sentence: \"\($0)\"" } ?? "Sentence: (not available)"
        if marked.count == 1 {
            return "\(context)\nMarked: \"\(marked[0])\""
        }
        let list = marked.enumerated().map { "\($0.offset + 1). \"\($0.element)\"" }.joined(separator: "\n")
        return "\(context)\nMarked (explain each one, in this order):\n\(list)"
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "marked": ["type": "string"],
                        "lemma": ["type": "string"],
                        "part_of_speech": ["type": "string"],
                        "ipa": ["type": "string"],
                        "hebrew": ["type": "string"],
                        "meaning": ["type": "string"],
                        "meaning_here": ["type": "string"],
                        "example": ["type": "string"],
                    ],
                    "required": ["marked", "lemma", "part_of_speech", "ipa", "hebrew", "meaning", "meaning_here", "example"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["items"],
        "additionalProperties": false,
    ]

    private static func apiErrorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }
}
