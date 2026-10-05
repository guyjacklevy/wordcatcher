import AppKit
import ApplicationServices
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let store = WordStore()
    private lazy var cloud = CloudSync(store: store)
    private lazy var popup = PopupController(store: store)
    private lazy var windows = WindowsController(store: store, cloud: cloud)
    private var syncTimer: Timer?
    private var syncItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        installStatusItem()

        popup.openAPIKeySettings = { [weak self] in self?.windows.showAPIKey() }
        store.onChange = { [weak self] in self?.cloud.syncSoon() }

        // Push anything saved while offline: now, and every 10 minutes.
        Task { await cloud.sync() }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.cloud.sync() }
        }
        popup.openAccessibilitySettings = { [weak self] in self?.openAccessibilitySettings() }

        // ⌃⌥T: "T" for translate.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            Task { @MainActor in await self?.markSelection() }
        }

        // First run: ask for Accessibility (needed to read the selection) and for the API key.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if Keychain.isMissing { windows.showAPIKey() }
        if !cloud.isSignedIn { windows.showSync() }

        Log.write("launched, accessibility=\(AXIsProcessTrusted()) key=\(Keychain.hasAPIKey) cloud=\(cloud.isSignedIn)")
    }

    private func markSelection() async {
        let point = NSEvent.mouseLocation
        guard AXIsProcessTrusted() else {
            popup.showError(
                "Word Catcher needs Accessibility permission to read what you selected. Turn it on in System Settings, then try again.",
                action: .accessibility, at: point
            )
            return
        }
        guard let capture = await SelectionReader.read() else {
            popup.showError("Select a word first, then press ⌃⌥T.", action: nil, at: point)
            return
        }
        popup.start(capture: capture, at: point)
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Word Catcher")

        let menu = NSMenu()
        let mark = NSMenuItem(title: "Translate selected word", action: #selector(markFromMenu), keyEquivalent: "t")
        mark.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(mark)
        menu.addItem(.separator())
        let sync = NSMenuItem(title: "Sync with your phone…", action: #selector(showSync), keyEquivalent: "")
        menu.addItem(sync)
        syncItem = sync
        menu.addItem(NSMenuItem(title: "My words…", action: #selector(showWords), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Claude API key…", action: #selector(showAPIKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Accessibility permission…", action: #selector(openAccessibilityFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Word Catcher", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Without an Edit menu, ⌘V doesn't paste into text fields (like the API key field).
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    /// Shows at a glance whether words reach the phone.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let session = cloud.session {
            syncItem?.title = cloud.lastError == nil ? "Phone sync on · \(session.email)" : "Phone sync: problem, click to see"
        } else {
            syncItem?.title = "Turn on phone sync…"
        }
    }

    @objc private func markFromMenu() { Task { await markSelection() } }
    @objc private func showWords() { windows.showWords() }
    @objc private func showSync() { windows.showSync() }
    @objc private func showAPIKey() { windows.showAPIKey() }
    @objc private func openAccessibilityFromMenu() { openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
