import AppKit
import SwiftUI

/// First-run window: explains Full Disk Access, watches for the grant, then shows the popup hotkey.
struct WelcomeView: View {
    @ObservedObject var store: NoteIndexStore
    @ObservedObject var user: UserStore
    let onDone: () -> Void
    @State private var granted = NotesReader.hasAccess
    @State private var openedSettings = false
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to NoteSleuth").font(.title2.bold())
                    Text("Search all your Apple Notes from anywhere, instantly.").foregroundStyle(.secondary)
                }
            }

            step(1, done: granted, title: "Allow Full Disk Access") {
                Text("Notes keeps its database in a folder macOS protects. NoteSleuth only reads it, keeps the index in memory, and never sends anything off your Mac.")
                if !granted {
                    HStack {
                        Button("Open Full Disk Access Settings") {
                            openedSettings = true
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    }
                    Text("Turn on NoteSleuth in the list, or drag it there from Finder.").font(.caption).foregroundStyle(.secondary)
                    if openedSettings {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for access… If you already allowed it,").font(.caption).foregroundStyle(.secondary)
                            Button("Quit & Reopen") { Self.relaunch() }.controlSize(.small)
                        }
                    }
                }
            }

            step(2, done: false, title: "Press \(user.popupShortcut.display) to search") {
                Text("Type words or #hashtags, then ↩ to open the note. Change the hotkey, launch at login and more in Settings.")
                Text("The first time you open a note, macOS asks to let NoteSleuth control Notes. Click Allow.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(granted ? "Get Started" : "Later", action: onDone)
                    .keyboardShortcut(granted ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(poll) { _ in
            guard !granted, NotesReader.hasAccess else { return }
            granted = true
            store.start()
        }
    }

    private func step<C: View>(_ n: Int, done: Bool, title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2).foregroundStyle(done ? .green : .accentColor)
                .accessibilityLabel(done ? "Step \(n) done" : "Step \(n)")
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content().font(.callout)
            }
        }
    }

    /// Full Disk Access sometimes only applies to a fresh process.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
