import RackoonCore
import SwiftUI

/// `swift run` launches a bare executable with no .app bundle, so macOS treats it as a
/// background process. Promote it so the window and Dock icon appear. Harmless in a real bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppIcon.installDockIcon()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RackoonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.migrateLegacyDefaults()
    }

    /// Without a bundle the defaults domain is the executable name, with one it is the bundle id. Copy the keys
    /// across once from the earlier domains (`HomebaseMac`, then `RackoonMac` under `swift run`), before anything reads them.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "selectedServerID") == nil,
              defaults.object(forKey: "appearanceSelection") == nil else { return }
        let own = Bundle.main.bundleIdentifier
        for domain in ["RackoonMac", "HomebaseMac"] where domain != own {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for key in ["selectedServerID", "appearanceSelection", "terminalThemeID", "terminalHighlightOutput"] {
                if let value = old[key] { defaults.set(value, forKey: key) }
            }
            return
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AboutCommand()
            TerminalCommands()
        }

        Window("About Rackoon", id: AboutView.windowID) {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
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

struct AboutCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Rackoon") { openWindow(id: AboutView.windowID) }
        }
    }
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
    private let appearance = AppearanceStore.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection, servers: model.servers, selectedID: model.selectedID, status: status,
                    updates: updateBadge,
                    onSelect: { selection = .overview; model.select($0) },
                    onRemove: { terminals.closeAll(for: $0); model.remove($0) },
                    onAddServer: { showingAdd = true })
            Divider()
            detail
        }
        .background(Theme.background)
        .frame(minWidth: 1080, minHeight: 600)
        // The theme drives the whole window: accent for controls, light/dark for system-drawn parts, and
        // every open terminal is recoloured when the resolved theme changes.
        .tint(Theme.accent)
        .preferredColorScheme(appearance.fixedColorScheme)
        .onChange(of: appearance.resolvedTheme) { _, theme in terminals.applyTheme(theme) }
        .onChange(of: appearance.highlightOutput) { _, _ in terminals.highlightSettingChanged() }
        .onAppear {
            appearance.applyWindowAppearance()
            model.start()
            if model.servers.isEmpty { showingAdd = true }
        }
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

    private var updateBadge: UpdateBadge? {
        // RACKOON_DEMO_UPDATES=1 pretends there are updates (see UpdatesModel), so the dot can be seen.
        if ProcessInfo.processInfo.environment["RACKOON_DEMO_UPDATES"] != nil { return UpdateBadge(total: 5, security: 2) }
        guard let o = model.state.overview else { return nil }
        return UpdateBadge(total: o.pendingUpdates, security: o.securityUpdates)
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
                    DockerScreen(server: server, theme: appearance.resolvedTheme, openShell: { container in
                        guard let command = DockerSession.shellCommand(id: container.id) else { return }
                        terminals.newTab(for: server, title: "Shell · \(container.service ?? container.name)", command: command)
                        selection = .terminal
                    }).id(server.id)
                case .updates:
                    UpdatesScreen(server: server).id(server.id)
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
                .foregroundStyle(Theme.textMuted)
        }
    }
}
