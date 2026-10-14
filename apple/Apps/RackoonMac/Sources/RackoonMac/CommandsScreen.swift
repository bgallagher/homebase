import AppKit
import RackoonCore
import SwiftUI

/// The Commands tab: a library of handy commands grouped by topic. Reading commands run on one click with live output;
/// commands that change the server show a dry-run preview and ask first. The free-form box asks every time.
struct CommandsScreen: View {
    let server: Server
    let theme: TerminalTheme
    let workspace: DockerWorkspace
    /// Opens a terminal tab running a command (for interactive ones like top).
    let openInTerminal: (String, String) -> Void
    /// Owned by the workspace, not built here: a view's `@State` default is rebuilt on every parent update, and keeping it in
    /// the workspace also keeps a running command and its output when you switch to another screen and back.
    private let model: CommandsModel

    init(server: Server, theme: TerminalTheme, workspace: DockerWorkspace, openInTerminal: @escaping (String, String) -> Void) {
        self.server = server
        self.theme = theme
        self.workspace = workspace
        self.openInTerminal = openInTerminal
        model = workspace.commandsModel(for: server)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            list.frame(width: 300)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 32).padding(.top, Theme.pageTop).padding(.bottom, 24)
        .foregroundStyle(Theme.textPrimary)
        .onAppear {
            let docker = workspace.model(for: server)
            docker.attach()   // so the container menu has something to show: the list comes from the Docker poll
            model.attach(openInTerminal: openInTerminal,
                         containerNames: { (docker.state.snapshot?.containers ?? []).map(\.name).sorted() })
        }
        .onDisappear { workspace.model(for: server).detach() }
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
        .sudoPassword(Binding(get: { model.sudoRequest }, set: { model.sudoRequest = $0 }))
    }

    // MARK: list

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commands").font(.system(size: 26, weight: .bold)).tracking(-0.4)
            TextField("Search", text: Bindable(model).search).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    row("Custom command…", symbol: "chevron.left.forwardslash.chevron.right", selected: model.selection == .custom, asks: true) {
                        model.select(.custom)
                    }
                    ForEach(model.visibleGroups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(Theme.textMuted).padding(.horizontal, 10).padding(.bottom, 4)
                            ForEach(group.commands) { c in
                                row(c.title, symbol: c.interactive ? "terminal" : nil, selected: model.selection == .library(c.id), asks: c.isMutating) {
                                    model.select(.library(c.id))
                                }
                            }
                        }
                    }
                    if model.visibleGroups.isEmpty { Text("No commands match.").foregroundStyle(Theme.textMuted).padding(.horizontal, 10) }
                }
            }
        }
    }

    private func row(_ title: String, symbol: String?, selected: Bool, asks: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.textMuted).frame(width: 14) }
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if asks { Image(systemName: "hand.raised").font(.system(size: 10)).foregroundStyle(Theme.warn).help("Asks before running") }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
    }

    // MARK: detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let command = model.selected {
                libraryDetail(command)
            } else {
                customDetail
            }
            if let message = model.message { ErrorBanner(message: message) }
            output
        }
    }

    private func libraryDetail(_ command: LibraryCommand) -> some View {
        let blocked = model.blockedReason(for: command)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(command.title).font(.system(size: 20, weight: .semibold))
                if command.isMutating { Badge(text: "Asks first", color: Theme.warn) }
                Spacer()
                if model.previewing { ProgressView().controlSize(.small) }
                Button(command.interactive ? "Open in Terminal" : (command.isMutating ? "Review and Run…" : "Run")) { model.run(command) }
                    .buttonStyle(.borderedProminent).controlSize(.large).handCursor()
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocked != nil).help(blocked ?? command.summary)
            }
            Text(command.summary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach(command.params, id: \.id) { p in
                HStack(spacing: 8) {
                    Text(p.label).foregroundStyle(Theme.textMuted).frame(width: 80, alignment: .leading)
                    TextField(p.placeholder, text: Binding(get: { model.params[p.id] ?? "" }, set: { model.params[p.id] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).onSubmit { model.run(command) }
                    if p.kind == .container, !model.knownContainers.isEmpty {
                        Menu {
                            ForEach(model.knownContainers, id: \.self) { n in Button(n) { model.params[p.id] = n } }
                        } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Containers on this server")
                    }
                }
            }
            if let warning = command.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScriptPreview(
                heading: command.interactive ? "Opens a terminal tab on \(server.name) running" : "Runs on \(server.name)",
                script: command.readableScript(params: model.params),
                exact: command.fullScript(params: model.params),
                dryRun: command.preview.map { command.readableScript($0, params: model.params) },
                note: command.root ? "sudo runs without asking first (sudo -n). If the server wants a password, Rackoon asks for it." : nil,
                theme: theme)
        }
    }

    private var customDetail: some View {
        let blocked = model.customBlockedReason
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Custom command").font(.system(size: 20, weight: .semibold))
                Badge(text: "Asks first", color: Theme.warn)
                Spacer()
                Button("Review and Run…") { model.runCustom() }
                    .buttonStyle(.borderedProminent).controlSize(.large).handCursor()
                    .disabled(blocked != nil).help(blocked ?? "Shows the exact command and asks before running it")
            }
            Text("Type any command. It runs over SSH as your user and is shown to you first, because Rackoon can't tell a harmless command from a destructive one.")
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("uname -a", text: Bindable(model).customText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).lineLimit(1...4)
                    .onSubmit { model.runCustom() }
                if !model.history.isEmpty {
                    Menu {
                        ForEach(model.history, id: \.self) { h in Button(h) { model.useFromHistory(h) } }
                        Divider()
                        Button("Clear History", role: .destructive) { model.clearHistory() }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Recent commands")
                }
            }
        }
    }

    private var emptyOutputText: String {
        guard let command = model.selected else { return "The custom command's output appears here." }
        if command.interactive { return "\(command.title) opens in a terminal tab." }
        return "\(command.title): output appears here when it runs."
    }

    @ViewBuilder private var output: some View {
        if let run = model.output {
            VStack(spacing: 0) {
                ActionOutputPanel(run: run, theme: theme, cancel: { model.cancelOutput() }, close: { model.dismissOutput() })
                if !run.isRunning {
                    HStack {
                        Spacer()
                        CopyButton(text: model.outputText, what: "output")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.sidebar.opacity(0.6))
                }
            }
            .frame(minHeight: 360, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 22)).foregroundStyle(Theme.textMuted)
                Text(emptyOutputText).foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
            .background(Color(nsColor: theme.backgroundRGB.nsColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
        }
    }
}

/// What a library command will run, shown before it runs: the readable script (guards left out, `sudo` spelled out,
/// parameters filled in), the dry run of a mutating command, and the exact script behind a disclosure.
private struct ScriptPreview: View {
    let heading: String
    let script: String
    /// The exact text that is sent, or nil while a parameter is missing or invalid.
    let exact: String?
    let dryRun: String?
    let note: String?
    let theme: TerminalTheme
    @State private var showExact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            block(heading, script)
            if let dryRun { block("Dry run first (read-only, shown before you confirm)", dryRun) }
            HStack(spacing: 12) {
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                if exact != nil {
                    Button(showExact ? "Hide exact script" : "Show exact script") { showExact.toggle() }
                        .buttonStyle(.link).font(.system(size: 11)).handCursor()
                }
            }
            if showExact, let exact { block("Exact script sent over SSH", exact) }
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
                Spacer()
                CopyButton(text: text, what: "command")
            }
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(nsColor: theme.foregroundRGB.nsColor))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(nsColor: theme.backgroundRGB.nsColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
    }
}
