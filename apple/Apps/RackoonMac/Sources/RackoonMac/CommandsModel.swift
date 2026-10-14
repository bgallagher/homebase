import Foundation
import RackoonCore
import RackoonSSHSystem

/// State of the Commands tab: which command is selected, its parameters, the run in progress and its output, the
/// confirmation for commands that change the server, and the history of custom commands.
@MainActor @Observable
final class CommandsModel {
    /// Either a library entry or the free-form box.
    enum Selection: Hashable { case custom, library(String) }

    var selection: Selection = .library("disk_usage")
    var search = ""
    var params: [String: String] = [:]
    var customText = ""
    /// The last run of each command, so the right-hand side only ever shows the selected command's output. A run keeps
    /// going (and keeps its output) when another command is selected.
    private(set) var outputs: [Selection: ActionOutput] = [:]
    /// The command whose dry run is being fetched before its confirmation, if any.
    private(set) var previewingSelection: Selection?
    /// A note for each command (why it did not start, what sudo said), shown under that command only.
    private var messages: [Selection: String] = [:]
    var pending: PendingAction?
    /// A root entry was refused because sudo wants a password: asks for it, then runs the entry again with it.
    var sudoRequest: SudoRequest?
    /// Custom commands run in this session. Kept in memory only: a typed command can contain a password or a token, and
    /// secrets are never written to disk by this app.
    private(set) var history: [String] = []

    let serverName: String
    @ObservationIgnored private let server: Server
    @ObservationIgnored private let session: CommandLibrarySession
    @ObservationIgnored private var openInTerminal: (String, String) -> Void = { _, _ in }
    @ObservationIgnored private var containerNames: () -> [String] = { [] }

    /// Built once per server by `DockerWorkspace.commandsModel(for:)`, not by a view.
    init(server: Server) {
        self.server = server
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
    }

    /// The selected command's last run.
    var output: ActionOutput? { outputs[selection] }

    /// The selected command's note.
    var message: String? {
        get { messages[selection] }
        set { messages[selection] = newValue }
    }

    var previewing: Bool { previewingSelection == selection }

    /// The run in progress, whichever command it belongs to. One command runs at a time.
    private var activeRun: (selection: Selection, output: ActionOutput)? {
        outputs.first { $0.value.isRunning }.map { ($0.key, $0.value) }
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
    var isRunning: Bool { activeRun != nil || previewingSelection != nil }

    /// What is running, for the reason a Run button is disabled.
    private var busyReason: String {
        if let run = activeRun { return run.selection == selection ? "This command is running" : "\(run.output.title) is running" }
        return "Another command is getting ready"
    }

    /// Why running is unavailable right now, or nil.
    func blockedReason(for command: LibraryCommand) -> String? {
        if isRunning { return busyReason }
        if command.isMutating && SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if command.fullScript(params: params) == nil, !command.params.isEmpty {
            return "Enter a valid \(command.params.map { $0.label.lowercased() }.joined(separator: " and "))"
        }
        return nil
    }

    var customBlockedReason: String? {
        if SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if isRunning { return busyReason }
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
        let params = params
        let saved = command.root && SudoVault.shared.isRemembered(server)
        if !command.isMutating {
            if saved {
                // A root read with a saved password: Touch ID / Apple Watch / login password is the approval.
                let nonce = SudoElevation.makeNonce()
                if let elevated = session.passwordIntent(for: command, params: params, nonce: nonce) {
                    unlockAndLaunch(elevated, entry: (command, params, nil), nonce: nonce)
                    return
                }
            }
            guard let intent = session.intent(for: command, params: params) else { return }
            launch(intent, title: command.title, confirm: false, entry: (command, params, nil))
            return
        }
        // A change: show what it would do (a read-only dry run), then ask.
        previewingSelection = .library(command.id)
        Task { [self] in
            let preview = await session.preview(for: command, params: params)
            previewingSelection = nil
            let shown = preview.isEmpty ? nil : preview
            let nonce = SudoElevation.makeNonce()
            if saved, let elevated = session.passwordIntent(for: command, params: params, preview: shown, nonce: nonce) {
                // Confirm the exact command that will run (the password variant), then unlock the saved password.
                pending = PendingAction(
                    title: "\(command.title)?",
                    message: ([command.summary, command.warning].compactMap { $0 } + [SudoVault.useNote(server)]).joined(separator: " "),
                    serverName: serverName, command: elevated.command, destructive: true, preview: elevated.preview,
                    run: { [weak self] in self?.unlockAndLaunch(elevated, entry: (command, params, shown), nonce: nonce) })
                return
            }
            guard let intent = session.intent(for: command, params: params, preview: shown) else { return }
            pending = PendingAction(
                title: "\(command.title)?",
                message: [command.summary, command.warning].compactMap { $0 }.joined(separator: " "),
                serverName: serverName, command: intent.command, destructive: true, preview: intent.preview,
                run: { [weak self] in
                    self?.launch(intent, title: command.title, confirm: true, entry: (command, params, intent.preview))
                })
        }
    }

    /// Touch ID, the Apple Watch or the login password, then `elevated` (built with `nonce`) runs with the saved
    /// password. Cancelled: nothing runs. Changed or unreadable: it was forgotten, and the password sheet opens.
    private func unlockAndLaunch(_ elevated: Intent, entry: LibraryEntry, nonce: String) {
        let server = server
        Task {
            switch await SudoVault.shared.unlock(server, reason: SudoVault.reason(server, doing: entry.command.title)) {
            case .success(let password):
                launch(elevated, title: entry.command.title, confirm: entry.command.isMutating, entry: entry,
                       sudo: SudoCredential(password: password, nonce: nonce), source: .saved)
            case .failure(.cancelled):
                messages[.library(entry.command.id)] = SudoSecretError.cancelled.errorDescription
            case .failure(let error):
                // Forgotten or unusable in the meantime: ask for it rather than dropping the confirmed command.
                presentSudoSheet(entry, problem: error.sheetProblem)
            }
        }
    }

    /// Asks for the sudo password, then runs the entry's password variant with it (one nonce per attempt).
    private func presentSudoSheet(_ entry: LibraryEntry, problem: String?) {
        guard !(entry.command.isMutating && SafetyStore.shared.readOnly) else { return }
        let nonce = SudoElevation.makeNonce()
        guard let elevated = session.passwordIntent(for: entry.command, params: entry.params, preview: entry.preview, nonce: nonce) else { return }
        sudoRequest = SudoRequest(
            title: "\(entry.command.title) with sudo", server: server, command: elevated.command,
            problem: problem, destructive: entry.command.isMutating, canRemember: SudoVault.shared.canRemember,
            submit: { [weak self] password, remember in
                self?.launch(elevated, title: entry.command.title, confirm: entry.command.isMutating, entry: entry,
                             sudo: SudoCredential(password: password, nonce: nonce), source: .typed(remember: remember))
            })
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

    /// `entry` is the library entry behind the intent (custom commands have none): when sudo refuses it for want of a
    /// password, the password variant of that entry is offered. With `sudo`, `intent` must be that variant built with
    /// the same nonce, and sudo's one prompt is answered.
    private func launch(_ intent: Intent, title: String, confirm: Bool, entry: LibraryEntry? = nil,
                        sudo: SudoCredential? = nil, source: SudoPasswordSource? = nil) {
        // The output belongs to the command it was started from, even if another one is selected by the time it ends.
        let key: Selection = entry.map { .library($0.command.id) } ?? .custom
        guard activeRun == nil else {
            // Never swallow a confirmed command silently: say that nothing was started.
            messages[key] = "Another command is still running, so nothing was started. Try again when it has finished."
            return
        }
        messages[key] = nil   // a new run: the last one's note no longer applies
        let session = session
        let server = server
        let result = RunResult()
        outputs[key] = ActionOutput.launch(
            scope: "commands", title: title,
            intro: "\u{1B}[2m$ \(title)\u{1B}[0m\r\n",
            work: { cols, rows, onEvent in
                // The policy checks again here, so turning on Read-only after confirming still stops it.
                let confirmation = confirm ? (try? session.confirm(intent)) : nil
                result.set(await session.run(intent, confirmation: confirmation, cols: cols, rows: rows,
                                             sudo: sudo, onEvent: onEvent))
            },
            completion: { [weak self] in
                guard let run = result.value else { return }
                // Saving and forgetting must not depend on the screen still being open.
                if let sudo, run.sudo == .accepted, !run.sudoAsksEveryTime, source == .typed(remember: true) {
                    Task { await SudoVault.shared.remember(sudo.password, for: server) }
                }
                if source == .saved, run.sudoRejected { SudoVault.shared.forget(server.id) }
                guard let self, let entry else { return }
                if let problem = run.sudoProblem { self.messages[key] = problem }
                guard run.needsSudoPassword, !self.isRunning else { return }
                if source == .saved {
                    self.presentSudoSheet(entry, problem: "The saved sudo password was not accepted, so it was forgotten.")
                } else {
                    self.presentSudoSheet(entry, problem: run.sudoRejected ? "The server did not accept that password." : nil)
                }
            })
    }

    func cancelOutput() { output?.task?.cancel() }

    func dismissOutput() {
        guard output?.isRunning != true else { return }
        outputs[selection] = nil
    }

    /// The output as plain text, for the Copy button.
    var outputText: String { ANSI.strip(output?.chunks.joined() ?? "") }
}

/// A library entry with the values it ran with (and the dry-run text the user saw, for mutating entries).
typealias LibraryEntry = (command: LibraryCommand, params: [String: String], preview: String?)

/// Carries a streamed run's result from the work closure to the completion.
private final class RunResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StreamedRun?
    func set(_ run: StreamedRun?) { lock.withLock { stored = run } }
    var value: StreamedRun? { lock.withLock { stored } }
}
