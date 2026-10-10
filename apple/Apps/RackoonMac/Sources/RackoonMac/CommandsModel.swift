import Foundation
import RackoonCore
import RackoonSSHSystem

/// State of the Commands tab: which command is selected, its parameters, the run in progress and its output, the
/// confirmation for commands that change the server, and the history of custom commands.
@MainActor @Observable
final class CommandsModel {
    /// Either a library entry or the free-form box.
    enum Selection: Equatable { case custom, library(String) }

    var selection: Selection = .library("disk_usage")
    var search = ""
    var params: [String: String] = [:]
    var customText = ""
    private(set) var output: ActionOutput?
    private(set) var previewing = false
    var message: String?
    var pending: PendingAction?
    /// Custom commands run in this session. Kept in memory only: a typed command can contain a password or a token, and
    /// secrets are never written to disk by this app.
    private(set) var history: [String] = []

    let serverName: String
    @ObservationIgnored private let session: CommandLibrarySession
    @ObservationIgnored private var openInTerminal: (String, String) -> Void = { _, _ in }
    @ObservationIgnored private var containerNames: () -> [String] = { [] }

    /// Built once per server by `DockerWorkspace.commandsModel(for:)`, not by a view.
    init(server: Server) {
        serverName = server.name
        session = CommandLibrarySession(transport: makeTransport(for: server), policy: SafetyStore.shared.policy)
    }

    func attach(openInTerminal: @escaping (String, String) -> Void, containerNames: @escaping () -> [String]) {
        self.openInTerminal = openInTerminal
        self.containerNames = containerNames
    }

    // MARK: choosing

    var selected: LibraryCommand? {
        if case .library(let id) = selection { return CommandLibrary.all.first { $0.id == id } }
        return nil
    }

    func select(_ new: Selection) {
        guard new != selection else { return }
        selection = new
        message = nil
    }

    /// Library entries matching the search, in their groups; empty groups are left out.
    var visibleGroups: [(name: String, commands: [LibraryCommand])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return CommandLibrary.groups.compactMap { group in
            let items = CommandLibrary.commands(in: group).filter {
                q.isEmpty || $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.id.contains(q)
            }
            return items.isEmpty ? nil : (group, items)
        }
    }

    var knownContainers: [String] { containerNames() }
    var isRunning: Bool { output?.isRunning == true || previewing }

    /// Why running is unavailable right now, or nil.
    func blockedReason(for command: LibraryCommand) -> String? {
        if isRunning { return "Another command is running" }
        if command.isMutating && SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if command.fullScript(params: params) == nil, !command.params.isEmpty {
            return "Enter a valid \(command.params.map { $0.label.lowercased() }.joined(separator: " and "))"
        }
        return nil
    }

    var customBlockedReason: String? {
        if SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if isRunning { return "Another command is running" }
        return session.customIntent(customText) == nil ? "Type a command" : nil
    }

    // MARK: running

    func run(_ command: LibraryCommand) {
        message = nil
        guard blockedReason(for: command) == nil else { message = blockedReason(for: command); return }
        guard let script = command.fullScript(params: params) else { return }
        if command.interactive {
            openInTerminal(command.title, script)
            return
        }
        if !command.isMutating {
            guard let intent = session.intent(for: command, params: params) else { return }
            launch(intent, title: command.title, confirm: false)
            return
        }
        // A change: show what it would do (a read-only dry run), then ask.
        previewing = true
        let params = params
        Task {
            let preview = await session.preview(for: command, params: params)
            previewing = false
            guard let intent = session.intent(for: command, params: params, preview: preview.isEmpty ? nil : preview) else { return }
            pending = PendingAction(
                title: "\(command.title)?",
                message: [command.summary, command.warning].compactMap { $0 }.joined(separator: " "),
                serverName: serverName, command: intent.command, destructive: true, preview: intent.preview,
                run: { [weak self] in self?.launch(intent, title: command.title, confirm: true) })
        }
    }

    func runCustom() {
        message = nil
        guard customBlockedReason == nil, let intent = session.customIntent(customText) else { message = customBlockedReason; return }
        pending = PendingAction(
            title: "Run this command on \(serverName)?",
            message: "Rackoon can't tell what a typed command does, so it asks every time. It runs as the ssh user, with no input.",
            serverName: serverName, command: intent.command, destructive: false,
            run: { [weak self] in
                self?.remember(intent.command)
                self?.launch(intent, title: intent.command, confirm: true)
            })
    }

    func useFromHistory(_ command: String) { customText = command }

    func clearHistory() { history = [] }

    private func remember(_ command: String) {
        history.removeAll { $0 == command }
        history.insert(command, at: 0)
        history = Array(history.prefix(20))
    }

    private func launch(_ intent: Intent, title: String, confirm: Bool) {
        guard output?.isRunning != true else {
            // Never swallow a confirmed command silently: say that nothing was started.
            message = "Another command is still running, so nothing was started. Try again when it has finished."
            return
        }
        let session = session
        output = ActionOutput.launch(
            scope: "commands", title: title,
            intro: "\u{1B}[2m$ \(title)\u{1B}[0m\r\n",
            work: { cols, rows, onEvent in
                // The policy checks again here, so turning on Read-only after confirming still stops it.
                let confirmation = confirm ? (try? session.confirm(intent)) : nil
                await session.run(intent, confirmation: confirmation, cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: {})
    }

    func cancelOutput() { output?.task?.cancel() }

    func dismissOutput() {
        guard output?.isRunning != true else { return }
        output = nil
    }

    /// The output as plain text, for the Copy button.
    var outputText: String { ANSI.strip(output?.chunks.joined() ?? "") }
}
