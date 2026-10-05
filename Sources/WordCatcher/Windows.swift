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
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?

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
                Text("On your phone, open the Word Catcher web app and sign in with the same email and password.")
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
                Text(creating
                     ? "Create your Word Catcher account. You'll use the same email and password on your phone."
                     : "Sign in to send your words to your phone. Use the same email and password on the Mac and the phone.")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                SecureField(creating ? "Choose a password (at least 6 characters)" : "Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(creating ? .newPassword : .password)
                if let info {
                    Text(info)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(creating ? "I already have an account" : "New here? Create an account") {
                        creating.toggle()
                        error = nil
                        info = nil
                    }
                    .buttonStyle(.link)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(creating ? "Create account" : "Sign in") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || email.trimmed.isEmpty || password.count < 6)
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
        info = nil
        let address = email.trimmed.lowercased()
        Task {
            do {
                if creating {
                    let signedIn = try await cloud.createAccount(email: address, password: password)
                    if !signedIn {
                        info = "Almost done: Supabase emailed you a link. Click it to confirm your email, then sign in here."
                        creating = false
                    }
                } else {
                    try await cloud.signIn(email: address, password: password)
                }
                if cloud.isSignedIn { password = "" }
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
