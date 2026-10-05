import Foundation

/// One time the user met a word: the sentence, where, and when.
struct Encounter: Codable, Hashable, Identifiable {
    var id: UUID
    var marked: String
    var sentence: String?
    var meaningHere: String
    var app: String
    var date: Date
    var synced: Bool

    init(marked: String, sentence: String?, meaningHere: String, app: String, date: Date) {
        id = UUID()
        self.marked = marked
        self.sentence = sentence
        self.meaningHere = meaningHere
        self.app = app
        self.date = date
        synced = false
    }

    // Older words.json files have no id or sync flag.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        marked = try c.decode(String.self, forKey: .marked)
        sentence = try c.decodeIfPresent(String.self, forKey: .sentence)
        meaningHere = try c.decode(String.self, forKey: .meaningHere)
        app = try c.decode(String.self, forKey: .app)
        date = try c.decode(Date.self, forKey: .date)
        synced = try c.decodeIfPresent(Bool.self, forKey: .synced) ?? false
    }
}

struct SavedWord: Codable, Identifiable, Hashable {
    var id: UUID
    var lemma: String
    var partOfSpeech: String
    var ipa: String
    var hebrew: String
    var meaning: String
    var example: String
    var status: String // new · learning · known
    var createdAt: Date
    var encounters: [Encounter]
    var synced: Bool

    var key: String { WordStore.key(for: lemma) }

    init(id: UUID, lemma: String, partOfSpeech: String, ipa: String, hebrew: String, meaning: String,
         example: String, status: String, createdAt: Date, encounters: [Encounter]) {
        self.id = id
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.ipa = ipa
        self.hebrew = hebrew
        self.meaning = meaning
        self.example = example
        self.status = status
        self.createdAt = createdAt
        self.encounters = encounters
        synced = false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        lemma = try c.decode(String.self, forKey: .lemma)
        partOfSpeech = try c.decode(String.self, forKey: .partOfSpeech)
        ipa = try c.decode(String.self, forKey: .ipa)
        hebrew = try c.decode(String.self, forKey: .hebrew)
        meaning = try c.decode(String.self, forKey: .meaning)
        example = try c.decode(String.self, forKey: .example)
        status = try c.decode(String.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        encounters = try c.decode([Encounter].self, forKey: .encounters)
        synced = try c.decodeIfPresent(Bool.self, forKey: .synced) ?? false
    }
}

/// What a save did, so the popup can describe it and Undo can reverse exactly that.
struct SaveOutcome: Hashable {
    enum Kind: Hashable { case added, sentenceAdded, alreadyHad }
    let kind: Kind
    let key: String
    let count: Int

    var note: String {
        switch kind {
        case .added: return "Saved to your words"
        case .sentenceAdded: return "Already in your words · this sentence added (\(count)×)"
        case .alreadyHad: return "Already in your words (seen \(count)×)"
        }
    }
}

/// Rows removed locally that the cloud still has.
struct PendingDeletes: Codable {
    var wordIDs: [UUID] = []
    var encounterIDs: [UUID] = []
}

/// Saved words, kept as JSON in ~/Library/Application Support/WordCatcher/words.json.
/// CloudSync pushes them to Supabase so the phone can review them.
@MainActor
final class WordStore: ObservableObject {
    @Published private(set) var words: [SavedWord] = []
    private(set) var pendingDeletes = PendingDeletes()
    private let fileURL: URL
    private let pendingURL: URL

    /// Called after every local change, so sync can follow.
    var onChange: () -> Void = {}

    nonisolated static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WordCatcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        fileURL = Self.supportDirectory.appendingPathComponent("words.json")
        pendingURL = Self.supportDirectory.appendingPathComponent("pending-deletes.json")
        load()
    }

    nonisolated static func key(for lemma: String) -> String { lemma.trimmed.lowercased() }

    func save(_ info: WordInfo, sentence: String?, app: String) -> SaveOutcome {
        let key = Self.key(for: info.lemma)
        let encounter = Encounter(marked: info.marked, sentence: sentence, meaningHere: info.meaningHere, app: app, date: Date())

        if let index = words.firstIndex(where: { $0.key == key }) {
            if let sentence, words[index].encounters.contains(where: { $0.sentence == sentence }) {
                return SaveOutcome(kind: .alreadyHad, key: key, count: words[index].encounters.count)
            }
            words[index].encounters.append(encounter)
            changed()
            return SaveOutcome(kind: .sentenceAdded, key: key, count: words[index].encounters.count)
        }

        let word = SavedWord(
            id: UUID(), lemma: info.lemma, partOfSpeech: info.partOfSpeech, ipa: info.ipa,
            hebrew: info.hebrew, meaning: info.meaning, example: info.example,
            status: "new", createdAt: Date(), encounters: [encounter]
        )
        words.insert(word, at: 0)
        changed()
        return SaveOutcome(kind: .added, key: key, count: 1)
    }

    func undo(_ outcome: SaveOutcome, sentence: String?) {
        guard let index = words.firstIndex(where: { $0.key == outcome.key }) else { return }
        switch outcome.kind {
        case .added:
            removeWord(at: index)
        case .sentenceAdded:
            if let last = words[index].encounters.lastIndex(where: { $0.sentence == sentence }) {
                let removed = words[index].encounters.remove(at: last)
                if removed.synced { pendingDeletes.encounterIDs.append(removed.id) }
            }
        case .alreadyHad:
            return
        }
        changed()
    }

    func delete(_ word: SavedWord) {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        removeWord(at: index)
        changed()
    }

    private func removeWord(at index: Int) {
        let removed = words.remove(at: index)
        if removed.synced { pendingDeletes.wordIDs.append(removed.id) }
    }

    // MARK: - Sync bookkeeping

    var unsyncedEncounters: [(UUID, Encounter)] {
        words.flatMap { word in word.encounters.filter { !$0.synced }.map { (word.id, $0) } }
    }

    func markWordsSynced(_ ids: Set<UUID>) {
        for index in words.indices where ids.contains(words[index].id) { words[index].synced = true }
        persist()
    }

    func markEncountersSynced(_ ids: Set<UUID>) {
        for w in words.indices {
            for e in words[w].encounters.indices where ids.contains(words[w].encounters[e].id) {
                words[w].encounters[e].synced = true
            }
        }
        persist()
    }

    func clearPendingDeletes(_ done: PendingDeletes) {
        pendingDeletes.wordIDs.removeAll { done.wordIDs.contains($0) }
        pendingDeletes.encounterIDs.removeAll { done.encounterIDs.contains($0) }
        persist()
    }

    // MARK: - Files

    private func changed() {
        persist()
        onChange()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL) {
            words = (try? decoder.decode([SavedWord].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: pendingURL) {
            pendingDeletes = (try? decoder.decode(PendingDeletes.self, from: data)) ?? PendingDeletes()
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(words) { try? data.write(to: fileURL, options: .atomic) }
        if let data = try? encoder.encode(pendingDeletes) { try? data.write(to: pendingURL, options: .atomic) }
    }
}
