import AppKit
import Combine
import Sparkle
import SwiftUI

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = NoteIndexStore()
    let user = UserStore.shared
    lazy var model = PopupModel(store: store, user: user)
    private var statusItem: NSStatusItem!
    private var panel: PopupPanel!
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var warnedShortcut: Shortcut?
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var keyMonitor: Any?
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        Pref.registerDefaults()
        setUpStatusItem()
        setUpPanel()
        model.onClose = { [weak self] in self?.hidePopup() }
        model.onOpenSettings = { [weak self] in self?.hidePopup(); self?.showSettings(tab: "index") }
        model.onToggleCompact = { [weak self] in self?.toggleCompact() }

        user.$popupShortcut.combineLatest(user.$noteHotkeys)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadHotkeys() }
            .store(in: &bag)
        ShortcutRecorder.onRecordingChanged = { [weak self] recording in
            recording ? HotKeyCenter.shared.unregisterAll() : self?.reloadHotkeys()
        }

        store.start()
        if !NotesReader.hasAccess || !UserDefaults.standard.bool(forKey: "welcomed") { showWelcome() }
    }

    // MARK: Hotkeys

    private func reloadHotkeys() {
        guard !ShortcutRecorder.isRecording else { return }
        let hk = HotKeyCenter.shared
        hk.unregisterAll()
        let taken = !hk.register(user.popupShortcut, action: { [weak self] in self?.togglePopup() })
        if taken, warnedShortcut != user.popupShortcut {
            warnedShortcut = user.popupShortcut
            DispatchQueue.main.async { [weak self] in self?.warnHotkeyTaken() }
        }
        for item in user.noteHotkeys {
            hk.register(item.shortcut) { [weak self] in self?.openNote(id: item.noteID) }
        }
        statusItem.menu?.item(withTag: 1)?.title = taken ? "Search Notes   (hotkey unavailable)" : "Search Notes   \(user.popupShortcut.display)"
    }

    /// Without this the popup silently never appears when another app owns the combination.
    private func warnHotkeyTaken() {
        let a = NSAlert()
        a.messageText = "The hotkey \(user.popupShortcut.display) is already in use"
        a.informativeText = "Another app or macOS itself has claimed it, so it can’t open NoteSleuth. Choose a different hotkey in Settings, or use the menu bar icon."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { showSettings(tab: "general") }
    }

    private func openNote(id: String) {
        guard let note = store.index.note(id: id) else { NSSound.beep(); return }
        user.recordOpen(id, tags: [])
        NotesOpener.open(note, storeUUID: store.storeUUID)
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "NoteSleuth")
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search Notes", action: #selector(togglePopup), keyEquivalent: "")
        search.tag = 1
        menu.addItem(search)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Rebuild Index", action: #selector(rebuildIndex), keyEquivalent: ""))
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NoteSleuth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        menu.insertItem(update, at: menu.items.count - 2)
        statusItem.menu = menu
    }

    @objc private func openSettings() { showSettings(tab: UserDefaults.standard.string(forKey: "settingsTab") ?? "general") }
    @objc private func rebuildIndex() { store.rebuild() }

    // MARK: Popup

    private func setUpPanel() {
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                           styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                           backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let host = NSHostingView(rootView: PopupView(model: model, user: user, store: store))
        host.sizingOptions = [.minSize]
        panel.contentView = host
        panel.setFrameAutosaveName("popup") // remembers the size and position you drag it to

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow, !ShortcutRecorder.isRecording else { return e }
            return self.model.handleKey(e) ? nil : e
        }
    }

    /// ⌘P: a small list-only popup, or the full one with the preview.
    private func toggleCompact() {
        let d = UserDefaults.standard
        let preview = !d.bool(forKey: Pref.showPreview)
        d.set(preview, forKey: Pref.showPreview)
        let size = preview ? NSSize(width: 1100, height: 700) : NSSize(width: 620, height: 460)
        var f = panel.frame // keep the search field where it is: same centre, same top edge
        f.origin.x += (f.width - size.width) / 2
        f.origin.y += f.height - size.height
        f.size = size
        panel.setFrame(f, display: true, animate: true)
    }

    /// `notesleuth://search?q=…` from Shortcuts, Raycast, Alfred or a link: opens the popup with that search.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let c = urls.first.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              c.scheme == "notesleuth", c.host == "search" else { return }
        let q = c.queryItems?.first { $0.name == "q" }?.value ?? ""
        if !panel.isVisible { showPopup() }
        model.query = String(q.prefix(500)) // untrusted input: it only ever becomes search text
    }

    @objc func togglePopup() {
        panel.isVisible ? hidePopup() : showPopup()
    }

    private func showPopup() {
        model.prepareForShow()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        // Keep a remembered position if it is on the screen you are using; otherwise centre there.
        let remembered = UserDefaults.standard.string(forKey: "NSWindow Frame popup") != nil
        if let f = screen?.visibleFrame, !(remembered && f.intersects(panel.frame)) {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + f.height * 0.62 - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .popupDidShow, object: nil)
    }

    private func hidePopup() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Give focus back to the app the user came from (unless Settings is up).
        if settingsWindow?.isVisible != true { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ n: Notification) {
        if (n.object as? NSWindow) === panel, !ShortcutRecorder.isRecording { panel.orderOut(nil) }
    }

    // MARK: Welcome

    private func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView(store: store, user: user) { [weak self] in
                UserDefaults.standard.set(true, forKey: "welcomed")
                self?.welcomeWindow?.close()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Welcome"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            welcomeWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Settings

    private func showSettings(tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, user: user, updater: updater.updater)))
            w.title = "NoteSleuth Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// `open -a NoteSleuth --args --diagnose <file>` writes the diagnostics report and quits (used to test real libraries).
if let i = CommandLine.arguments.firstIndex(of: "--diagnose"), i + 1 < CommandLine.arguments.count {
    try? Diagnostics.report().write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    exit(0)
}

// One-time copy of settings, favourites and hotkeys from before the app was renamed (must run before UserStore loads).
let defaults = UserDefaults.standard
if !defaults.bool(forKey: "migratedFromQuickNoteSearch") {
    for (k, v) in defaults.persistentDomain(forName: "io.github.giridharmb.QuickNoteSearch") ?? [:] where defaults.object(forKey: k) == nil {
        defaults.set(v, forKey: k)
    }
    defaults.set(true, forKey: "migratedFromQuickNoteSearch")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
