import Foundation

/// The Supabase project that holds the words. The publishable key is safe to ship in an app.
enum CloudConfig {
    static let url = URL(string: "https://aceyqtcljidnfzesqyjq.supabase.co")!
    static let publishableKey = "sb_publishable_XvYDHMwoBOU4gF-SzKRIIg_gZMzeSYb"
}

struct CloudSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String
}

enum CloudError: LocalizedError {
    case notSignedIn
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .server(_, let message) where message == "Invalid login credentials": return "Wrong email or password."
        case .server(_, let message) where message == "Email not confirmed": return "Confirm your email first: click the link Supabase sent you."
        case .server(let status, let message): return "Sync error (\(status)): \(message)"
        }
    }
}

/// Signs in with email + password and pushes saved words to the cloud, so the phone can review them.
/// The session lives in ~/Library/Application Support/WordCatcher/session.json, readable only by this user.
@MainActor
final class CloudSync: ObservableObject {
    @Published private(set) var session: CloudSession?
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncedAt: Date?

    private let store: WordStore
    private let sessionURL: URL
    private var isSyncing = false
    private var syncAgain = false
    private var debounce: Task<Void, Never>?

    init(store: WordStore) {
        self.store = store
        sessionURL = WordStore.supportDirectory.appendingPathComponent("session.json")
        session = loadSession()
    }

    var isSignedIn: Bool { session != nil }

    // MARK: - Sign in

    func signIn(email: String, password: String) async throws {
        let data = try await auth("token", query: "grant_type=password", body: ["email": email, "password": password])
        try storeSession(from: data, email: email)
        await sync()
    }

    /// Returns true when signed in right away, false when Supabase wants the email confirmed first.
    func createAccount(email: String, password: String) async throws -> Bool {
        let data = try await auth("signup", body: ["email": email, "password": password])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["access_token"] != nil else {
            return false
        }
        try storeSession(from: data, email: email)
        await sync()
        return true
    }

    func signOut() {
        session = nil
        try? FileManager.default.removeItem(at: sessionURL)
    }

    // MARK: - Sync

    /// Batches quick changes (save, then undo) into one push.
    func syncSoon() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard session != nil else { return }
        if isSyncing { syncAgain = true; return }
        isSyncing = true
        defer { isSyncing = false }

        repeat {
            syncAgain = false
            do {
                try await pushDeletes()
                try await pushWords()
                try await pushEncounters()
                lastError = nil
                lastSyncedAt = Date()
            } catch {
                lastError = error.localizedDescription
                Log.write("sync error: \(error.localizedDescription)")
                return
            }
        } while syncAgain
    }

    private func pushDeletes() async throws {
        let pending = store.pendingDeletes
        if !pending.encounterIDs.isEmpty {
            _ = try await rest("encounters", method: "DELETE", query: "id=in.(\(pending.encounterIDs.map(\.uuidString).joined(separator: ",")))")
        }
        if !pending.wordIDs.isEmpty {
            _ = try await rest("words", method: "DELETE", query: "id=in.(\(pending.wordIDs.map(\.uuidString).joined(separator: ",")))")
        }
        store.clearPendingDeletes(pending)
    }

    private func pushWords() async throws {
        let words = store.words.filter { !$0.synced }
        guard !words.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        let body: [[String: Any]] = words.map { word in
            [
                "id": word.id.uuidString,
                "lemma": word.lemma,
                "lemma_key": word.key,
                "part_of_speech": word.partOfSpeech,
                "ipa": word.ipa,
                "hebrew": word.hebrew,
                "meaning": word.meaning,
                "example": word.example,
                "created_at": iso.string(from: word.createdAt),
                // First review is the day after you meet the word (your local day).
                "due_on": Self.localDay(Calendar.current.date(byAdding: .day, value: 1, to: word.createdAt) ?? word.createdAt),
            ]
        }
        _ = try await rest("words", method: "POST", query: "on_conflict=id", body: body, prefer: "resolution=merge-duplicates,return=minimal")
        store.markWordsSynced(Set(words.map(\.id)))
    }

    private func pushEncounters() async throws {
        let pending = store.unsyncedEncounters
        guard !pending.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        let body: [[String: Any]] = pending.map { wordID, encounter in
            [
                "id": encounter.id.uuidString,
                "word_id": wordID.uuidString,
                "marked": encounter.marked,
                "sentence": encounter.sentence ?? NSNull(),
                "meaning_here": encounter.meaningHere,
                "app": encounter.app,
                "created_at": iso.string(from: encounter.date),
            ]
        }
        _ = try await rest("encounters", method: "POST", query: "on_conflict=id", body: body, prefer: "resolution=ignore-duplicates,return=minimal")
        store.markEncountersSynced(Set(pending.map(\.1.id)))
    }

    private static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - HTTP

    private func auth(_ path: String, query: String? = nil, body: [String: Any]) async throws -> Data {
        var components = URLComponents(url: CloudConfig.url.appendingPathComponent("auth/v1/\(path)"), resolvingAgainstBaseURL: false)!
        components.query = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(CloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func rest(_ table: String, method: String, query: String, body: Any? = nil, prefer: String? = nil) async throws -> Data {
        let token = try await validAccessToken()
        var components = URLComponents(url: CloudConfig.url.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(CloudConfig.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "prefer") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudError.server(status: status, message: Self.message(from: data))
        }
        return data
    }

    private static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["msg", "message", "error_description", "error"] {
                if let text = json[key] as? String { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }

    // MARK: - Session

    private func validAccessToken() async throws -> String {
        guard let current = session else { throw CloudError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        do {
            let data = try await auth("token", query: "grant_type=refresh_token", body: ["refresh_token": current.refreshToken])
            try storeSession(from: data, email: current.email)
        } catch CloudError.server(let status, _) where (400..<500).contains(status) {
            signOut() // the refresh token is no longer valid
            throw CloudError.notSignedIn
        }
        guard let refreshed = session else { throw CloudError.notSignedIn }
        return refreshed.accessToken
    }

    private func storeSession(from data: Data, email: String) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw CloudError.server(status: 0, message: "Unexpected sign-in response")
        }
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let signedIn = CloudSession(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn), email: email)
        session = signedIn
        if let encoded = try? JSONEncoder().encode(signedIn) {
            try? encoded.write(to: sessionURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
        }
    }

    private func loadSession() -> CloudSession? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(CloudSession.self, from: data)
    }
}
