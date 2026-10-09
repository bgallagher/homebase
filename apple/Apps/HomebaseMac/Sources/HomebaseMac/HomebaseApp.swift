import SwiftUI

/// `swift run` launches a bare executable with no .app bundle, so macOS treats it as a
/// background process. Promote it so the window and Dock icon appear. Harmless in a real bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct HomebaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    // Stage 3 replaces this with a saved server list; for now remember the last host.
    @AppStorage("lastHost") private var host = ""
    @State private var model = ServerModel()
    @State private var selection: Screen = .overview
    @State private var visitedTerminal = false
    @State private var showingAdd = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection, host: host, status: status) {
                draft = host
                showingAdd = true
            }
            Divider()
            detail
        }
        .background(Theme.background)
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { if host.isEmpty { showingAdd = true } else { model.connect(host: host) } }
        .onChange(of: host) { _, new in model.connect(host: new) }
        .onChange(of: selection) { _, new in if new == .terminal { visitedTerminal = true } }
        .sheet(isPresented: $showingAdd) { addServerSheet }
    }

    private var status: ConnectionStatus {
        let s = model.state
        if host.isEmpty { return .none }
        if s.error != nil { return .failing }
        return s.overview == nil ? .connecting : .connected
    }

    @ViewBuilder private var detail: some View {
        if host.isEmpty {
            ContentUnavailableView("No server yet", systemImage: "server.rack",
                                   description: Text("Add a host or a ~/.ssh/config alias to get started."))
        } else {
            ZStack {
                switch selection {
                case .overview:
                    OverviewView(model: model, host: host, openTerminal: { selection = .terminal })
                case .command:
                    CommandProbeView(host: host)
                default:
                    EmptyView()
                }
                // Keep the terminal alive while other screens are shown, or the SSH session would die.
                if visitedTerminal {
                    TerminalPane(host: host).id(host)
                        .padding(.horizontal, 12).padding(.top, 36).padding(.bottom, 12)
                        .background(Color.black)
                        .opacity(selection == .terminal ? 1 : 0)
                        .allowsHitTesting(selection == .terminal)
                }
            }
        }
    }

    private var addServerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add server").font(.title2.bold())
            Text("A hostname, user@host, or an alias from ~/.ssh/config. Uses your existing keys and ssh-agent.")
                .foregroundStyle(.secondary)
            TextField("hetzner or root@203.0.113.7", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            HStack {
                Spacer()
                if !host.isEmpty { Button("Cancel") { showingAdd = false } }
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func connect() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        showingAdd = false
        visitedTerminal = false
        selection = .overview
        if value == host { model.connect(host: value) } else { host = value }
    }
}
