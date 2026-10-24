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

/// One edit Claude made to the user's English, and why.
struct PolishChange: Codable, Hashable {
    let before: String
    let after: String
    let why: String
}

/// The user's English, improved.
struct PolishResult: Codable {
    let improved: String
    let verdict: String
    let changes: [PolishChange]
}

/// The selected text in English, with {0}, {1}… where each item's English goes.
struct ComposeResult: Codable {
    let template: String
    let items: [ComposeItem]
}

enum TranslatorError: LocalizedError {
    case notSignedIn
    case needsInvite
    case dailyLimit(String)
    case notReady
    case http(status: Int, message: String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to Word Catcher first. It's in the book icon menu: Account & phone sync."
        case .needsInvite: return "This account needs an invite code. Enter it in the book icon menu: Account & phone sync."
        case .dailyLimit(let message): return message
        case .notReady: return "Word Catcher's server isn't set up yet. Try again in a little while."
        case .http(let status, let message): return "Something went wrong (\(status)): \(message)"
        case .unreadable: return "The answer couldn't be read. Try again."
        }
    }

    /// The button the error card offers.
    var action: ErrorAction? {
        switch self {
        case .notSignedIn, .needsInvite: return .account
        default: return nil
        }
    }
}

/// Asks Claude through Word Catcher's server (the `ai` edge function), as the signed-in user.
/// The server holds the Claude key, checks the invite and daily limit, and logs usage.
enum Translator {
    /// Supplies the signed-in user's session token. Set by the app at launch.
    static var tokenProvider: (() async throws -> String)?

    static func explain(marked: [String], sentence: String?) async throws -> [WordInfo] {
        struct Payload: Decodable { let items: [WordInfo] }
        var input: [String: Any] = ["marked": marked]
        if let sentence { input["sentence"] = sentence }
        let payload: Payload = try await ask("explain", input)
        guard !payload.items.isEmpty else { throw TranslatorError.unreadable }
        return payload.items
    }

    static func compose(text: String, sentence: String?) async throws -> ComposeResult {
        var input: [String: Any] = ["text": text]
        if let sentence { input["sentence"] = sentence }
        let result: ComposeResult = try await ask("compose", input)
        let usable = result.items.filter { !$0.choices.isEmpty }
        guard !result.template.trimmed.isEmpty || !usable.isEmpty else { throw TranslatorError.unreadable }
        return ComposeResult(template: result.template, items: usable)
    }

    static func polish(_ text: String, style: String? = nil) async throws -> PolishResult {
        var input: [String: Any] = ["text": text]
        if let style { input["style"] = style }
        let result: PolishResult = try await ask("polish", input)
        guard !result.improved.trimmed.isEmpty else { throw TranslatorError.unreadable }
        return result
    }

    static func translateToHebrew(_ text: String) async throws -> String {
        struct Payload: Decodable { let translation: String }
        let payload: Payload = try await ask("translate_he", ["text": text])
        guard payload.translation.containsHebrew else { throw TranslatorError.unreadable }
        return payload.translation
    }

    // MARK: - HTTP

    private static func ask<T: Decodable>(_ task: String, _ input: [String: Any]) async throws -> T {
        guard let tokenProvider, let token = try? await tokenProvider() else { throw TranslatorError.notSignedIn }

        var request = URLRequest(url: CloudConfig.url.appendingPathComponent("functions/v1/ai"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(CloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("mac-\(appVersion)", forHTTPHeaderField: "x-client-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["task": task, "payload": input])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = json["message"] as? String ?? json["error"] as? String ?? "unknown error"

        switch status {
        case 200: break
        case 401: throw TranslatorError.notSignedIn
        case 403 where json["error"] as? String == "invite": throw TranslatorError.needsInvite
        case 429: throw TranslatorError.dailyLimit(message)
        case 503: throw TranslatorError.notReady
        default: throw TranslatorError.http(status: status, message: message)
        }

        guard let result = json["result"],
              let resultData = try? JSONSerialization.data(withJSONObject: result),
              let decoded = try? JSONDecoder().decode(T.self, from: resultData) else { throw TranslatorError.unreadable }
        return decoded
    }

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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
