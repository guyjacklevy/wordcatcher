import AppKit
import SwiftUI

/// The small windows the menu opens: API key, phone sync, and the saved words list.
@MainActor
final class WindowsController {
    private let store: WordStore
    private let cloud: CloudSync
    private var keyWindow: NSWindow?
    private var syncWindow: NSWindow?
    private var wordsWindow: NSWindow?

    init(store: WordStore, cloud: CloudSync) {
        self.store = store
        self.cloud = cloud
    }

    func showSync() {
        if syncWindow == nil {
            let window = makeWindow(title: "Sync with your phone", size: NSSize(width: 460, height: 240))
            window.contentViewController = NSHostingController(rootView: SyncView(cloud: cloud, store: store))
            syncWindow = window
        }
        present(syncWindow)
    }

    func showAPIKey() {
        if keyWindow == nil {
            let window = makeWindow(title: "Claude API key", size: NSSize(width: 460, height: 230))
            window.contentViewController = NSHostingController(rootView: APIKeyView { [weak window] in window?.close() })
            keyWindow = window
        }
        present(keyWindow)
    }

    func showWords() {
        if wordsWindow == nil {
            let window = makeWindow(title: "My words", size: NSSize(width: 520, height: 560))
            window.styleMask.insert(.resizable)
            window.contentViewController = NSHostingController(rootView: WordsListView(store: store))
            wordsWindow = window
        }
        present(wordsWindow)
    }

    private func makeWindow(title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct APIKeyView: View {
    @State private var key = ""
    @State private var hasKey = Keychain.hasAPIKey
    @State private var failed = false
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word Catcher uses Claude to explain each word you mark. Paste your API key from the Claude Console. It's stored in your Mac's Keychain and only sent to Anthropic.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            SecureField(hasKey ? "A key is saved. Paste a new one to replace it." : "Paste your API key", text: $key)
                .textFieldStyle(.roundedBorder)
            HStack {
                if hasKey {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12.5))
                } else if failed {
                    Text("Couldn't save to the Keychain.")
                        .foregroundColor(.red)
                        .font(.system(size: 12.5))
                }
                Spacer()
                Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 12.5))
                Button("Save") {
                    if Keychain.setAPIKey(key.trimmed) {
                        key = ""
                        hasKey = true
                        failed = false
                        onDone()
                    } else {
                        failed = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct SyncView: View {
    @ObservedObject var cloud: CloudSync
    @ObservedObject var store: WordStore
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = cloud.session {
                Label("Signed in as \(session.email)", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .medium))
                Text(status)
                    .font(.system(size: 12.5))
                    .foregroundColor(cloud.lastError == nil ? .secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On your phone, open the Word Catcher web app and sign in with the same email.")
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Sign out") { cloud.signOut() }
                    Spacer()
                    Button("Sync now") { Task { await cloud.sync() } }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Sign in to send your words to your phone. Use the same email on the Mac and the phone. We'll email you a 6-digit code.")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(codeSent)
                if codeSent {
                    TextField("Code from the email", text: $code)
                        .textFieldStyle(.roundedBorder)
                }
                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if codeSent {
                        Button("Use a different email") {
                            codeSent = false
                            code = ""
                            error = nil
                        }
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(codeSent ? "Sign in" : "Send code") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || email.trimmed.isEmpty || (codeSent && code.trimmed.isEmpty))
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var status: String {
        if let lastError = cloud.lastError { return lastError }
        let count = store.words.count
        guard let last = cloud.lastSyncedAt else { return "\(count) words on this Mac." }
        return "\(count) words · last synced \(last.formatted(date: .omitted, time: .shortened))"
    }

    private func submit() {
        busy = true
        error = nil
        let address = email.trimmed.lowercased()
        let token = code.filter(\.isNumber)
        Task {
            do {
                if codeSent {
                    try await cloud.verify(email: address, code: token)
                    code = ""
                    codeSent = false
                } else {
                    try await cloud.sendCode(to: address)
                    codeSent = true
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct WordsListView: View {
    @ObservedObject var store: WordStore

    var body: some View {
        if store.words.isEmpty {
            VStack(spacing: 8) {
                Text("No words yet")
                    .font(.system(size: 15, weight: .semibold))
                Text("Select a word in any app and press ⌃⌥T.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.words) { word in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(word.lemma).font(.system(size: 15, weight: .semibold))
                            Text(word.partOfSpeech).font(.system(size: 12)).foregroundColor(.secondary)
                            Spacer()
                            Text(word.hebrew).font(.system(size: 15, weight: .medium))
                        }
                        if let sentence = word.encounters.last?.sentence {
                            Text(sentence)
                                .font(.system(size: 12.5, design: .serif).italic())
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Text(meta(for: word))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Say it") { Speaker.say(word.lemma) }
                        Button("Delete", role: .destructive) { store.delete(word) }
                    }
                }
            }
        }
    }

    private func meta(for word: SavedWord) -> String {
        let app = word.encounters.last?.app ?? ""
        let date = word.encounters.last?.date.formatted(date: .abbreviated, time: .omitted) ?? ""
        let seen = word.encounters.count > 1 ? " · seen \(word.encounters.count)×" : ""
        return "\(app) · \(date)\(seen)"
    }
}
