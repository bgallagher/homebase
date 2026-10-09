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
        .commands {
            TerminalCommands()
        }
    }
}

/// What the Terminal menu items act on. Published by the front window only while a terminal is showing.
struct TerminalActions {
    var newTab: () -> Void
    var closeTab: () -> Void
}

extension FocusedValues {
    @Entry var terminalActions: TerminalActions?
}

struct TerminalCommands: Commands {
    @FocusedValue(\.terminalActions) private var actions

    var body: some Commands {
        // Replace File > Close so Cmd+W closes the current tab when a terminal is showing,
        // and still closes the window everywhere else.
        CommandGroup(replacing: .saveItem) {
            Button("New Terminal Tab") { actions?.newTab() }
                .keyboardShortcut("t")
                .disabled(actions == nil)
            Button(actions == nil ? "Close Window" : "Close Tab") {
                if let actions { actions.closeTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var selection: Screen = .overview
    @State private var terminals = TerminalStore()
    @State private var showingAdd = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection, servers: model.servers, selectedID: model.selectedID, status: status,
                    onSelect: { selection = .overview; model.select($0) },
                    onRemove: { terminals.closeAll(for: $0); model.remove($0) },
                    onAddServer: { showingAdd = true })
            Divider()
            detail
        }
        .background(Theme.background)
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { model.start(); if model.servers.isEmpty { showingAdd = true } }
        .focusedSceneValue(\.terminalActions, terminalActions)
        .sheet(isPresented: $showingAdd) {
            AddServerSheet(existing: model.servers, canCancel: !model.servers.isEmpty) { server in
                showingAdd = false
                selection = .overview
                model.add(server)
            } onCancel: { showingAdd = false }
        }
        .sheet(isPresented: pendingTrust) {
            if case .needsTrust(let offer) = model.phase, let server = model.selected {
                HostKeySheet(server: server, offer: offer, onTrust: model.trustPending, onCancel: model.declineTrust)
            }
        }
    }

    private var terminalActions: TerminalActions? {
        guard selection == .terminal, let server = model.selected else { return nil }
        return TerminalActions(
            newTab: { terminals.newTab(for: server) },
            closeTab: { if let tab = terminals.selectedTab(for: server) { terminals.close(tab, for: server) } })
    }

    private var pendingTrust: Binding<Bool> {
        Binding(
            get: { if case .needsTrust = model.phase { true } else { false } },
            set: { if !$0 { model.declineTrust() } })
    }

    private var status: ConnectionStatus {
        switch model.phase {
        case .blocked: .failing
        case .idle where model.state.error != nil: .failing
        case .polling:
            model.state.error != nil ? .failing : (model.state.overview == nil || model.state.isStale ? .connecting : .connected)
        default: .connecting
        }
    }

    @ViewBuilder private var detail: some View {
        if let server = model.selected {
            ZStack {
                switch selection {
                case .overview:
                    OverviewView(model: model, server: server, openTerminal: { selection = .terminal },
                                 openScreen: { fix in if let s = Screen(rawValue: fix), s.isAvailable { selection = s } })
                case .docker:
                    DockerScreen(server: server, theme: terminals.theme).id(server.id)
                case .terminal:
                    TerminalScreen(store: terminals, server: server)
                case .command:
                    CommandProbeView(server: server).id(server.id)
                default:
                    EmptyView()
                }
            }
        } else {
            ContentUnavailableView("No server yet", systemImage: "server.rack",
                                   description: Text("Add a host or a ~/.ssh/config alias to get started."))
        }
    }
}
