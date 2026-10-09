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
    @State private var model = AppModel()
    @State private var selection: Screen = .overview
    @State private var visitedTerminal = false
    @State private var showingAdd = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection, servers: model.servers, selectedID: model.selectedID, status: status,
                    onSelect: { visitedTerminal = false; selection = .overview; model.select($0) },
                    onRemove: { visitedTerminal = false; model.remove($0) },
                    onAddServer: { showingAdd = true })
            Divider()
            detail
        }
        .background(Theme.background)
        .frame(minWidth: 960, minHeight: 600)
        .onAppear { model.start(); if model.servers.isEmpty { showingAdd = true } }
        .onChange(of: selection) { _, new in if new == .terminal { visitedTerminal = true } }
        .sheet(isPresented: $showingAdd) {
            AddServerSheet(existing: model.servers, canCancel: !model.servers.isEmpty) { server in
                showingAdd = false
                visitedTerminal = false
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
                    OverviewView(model: model, server: server, openTerminal: { selection = .terminal })
                case .command:
                    CommandProbeView(server: server).id(server.id)
                default:
                    EmptyView()
                }
                // Keep the terminal alive while other screens are shown, or the SSH session would die.
                if visitedTerminal {
                    TerminalPane(server: server).id(server.id)
                        .padding(.horizontal, 12).padding(.top, 36).padding(.bottom, 12)
                        .background(Color.black)
                        .opacity(selection == .terminal ? 1 : 0)
                        .allowsHitTesting(selection == .terminal)
                }
            }
        } else {
            ContentUnavailableView("No server yet", systemImage: "server.rack",
                                   description: Text("Add a host or a ~/.ssh/config alias to get started."))
        }
    }
}
