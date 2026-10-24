import AppKit
import SwiftUI

/// The small windows the menu opens: account (sign-in and phone sync) and the saved words list.
@MainActor
final class WindowsController {
    private let store: WordStore
    private let cloud: CloudSync
    private var syncWindow: NSWindow?
    private var wordsWindow: NSWindow?

    init(store: WordStore, cloud: CloudSync) {
        self.store = store
        self.cloud = cloud
    }

    func showSync() {
        if syncWindow == nil {
            let window = makeWindow(title: "Word Catcher account", size: NSSize(width: 460, height: 260))
            window.contentViewController = NSHostingController(rootView: SyncView(cloud: cloud, store: store))
            syncWindow = window
        }
        Task { await cloud.refreshAccount() }
        present(syncWindow)
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

struct SyncView: View {
    @ObservedObject var cloud: CloudSync
    @ObservedObject var store: WordStore
    @State private var email = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var creating = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = cloud.session {
                signedIn(session)
            } else {
                signInForm
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedIn(_ session: CloudSession) -> some View {
        Label("Signed in as \(session.email)", systemImage: "checkmark.circle.fill")
            .foregroundColor(.green)
            .font(.system(size: 13, weight: .medium))

        if let account = cloud.account, !account.activated {
            // Signed in, but no invite yet: the AI features stay off until one is entered.
            Text("Enter your invite code to start using Word Catcher.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Invite code (WC-XXXX-XXXX)", text: $invite)
                    .textFieldStyle(.roundedBorder)
                if busy { ProgressView().controlSize(.small) }
                Button("Activate") { submit { try await cloud.redeem(invite: invite.trimmed) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || invite.trimmed.isEmpty)
            }
            errorText
        } else {
            Text(status)
                .font(.system(size: 12.5))
                .foregroundColor(cloud.lastError == nil ? .secondary : .red)
                .fixedSize(horizontal: false, vertical: true)
            if let account = cloud.account {
                Text("Today: \(account.usedToday) of \(account.dailyLimit) lookups")
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
            }
            Text("On your phone, open wordcatcher-web.vercel.app and sign in with the same email and password.")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button("Sign out") { cloud.signOut() }
            Spacer()
            if cloud.account?.isAdmin == true {
                Link("Usage & invites", destination: URL(string: "https://wordcatcher-web.vercel.app/admin")!)
                    .font(.system(size: 12.5))
            }
            Button("Sync now") { Task { await cloud.sync() } }
        }
    }

    // MARK: - Signed out

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(creating
                 ? "Create your account with the invite code you got. You'll use the same email and password on your phone."
                 : "Sign in to use Word Catcher. Use the same email and password on the Mac and the phone.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
            SecureField(creating ? "Choose a password (at least 6 characters)" : "Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(creating ? .newPassword : .password)
            if creating {
                TextField("Invite code (WC-XXXX-XXXX)", text: $invite)
                    .textFieldStyle(.roundedBorder)
            }
            errorText
            HStack {
                Button(creating ? "I already have an account" : "Have an invite? Create an account") {
                    creating.toggle()
                    error = nil
                }
                .buttonStyle(.link)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(creating ? "Create account" : "Sign in") {
                    let address = email.trimmed.lowercased()
                    let code = invite.trimmed
                    let secret = password
                    submit {
                        if creating {
                            try await cloud.createAccount(email: address, password: secret, invite: code)
                        } else {
                            try await cloud.signIn(email: address, password: secret)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || email.trimmed.isEmpty || password.count < 6 || (creating && invite.trimmed.isEmpty))
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error {
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: String {
        if let lastError = cloud.lastError { return lastError }
        let count = store.words.count
        guard let last = cloud.lastSyncedAt else { return "\(count) words on this Mac." }
        return "\(count) words · last synced \(last.formatted(date: .omitted, time: .shortened))"
    }

    private func submit(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await work()
                password = ""
                invite = ""
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
