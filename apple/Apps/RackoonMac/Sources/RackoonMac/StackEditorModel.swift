import Foundation
import RackoonCore
import RackoonSSHSystem

/// State of the compose/.env editor for one stack: the files opened so far (each with the user's draft), the
/// server-side checks of those drafts, and saving. Reads and checks change nothing on the server.
@MainActor @Observable
final class StackEditorModel {
    struct Draft {
        /// What the server had when the file was opened. Nil until loaded.
        var original: RemoteFileState?
        var text = ""
        var loading = false
        var loadError: String?
        var validation: ValidationResult?
        /// The text `validation` belongs to, so a result for older text is never shown as current.
        var validatedText: String?
        var checkError: String?
        /// Instant local checks (`.env` syntax).
        var local: [ComposeIssue] = []
    }

    enum Notice: Equatable {
        case saved(file: String, redeployed: Bool)
        case changedOnServer(EditableFile)
        case failed(String)
    }

    let stack: DockerStack
    let files: [EditableFile]
    private(set) var drafts: [EditableFile: Draft] = [:]
    private(set) var checking: Set<EditableFile> = []
    private(set) var saving = false
    var notice: Notice?
    var pending: PendingAction?

    @ObservationIgnored private let session: StackFileSession
    @ObservationIgnored private let serverName: String
    @ObservationIgnored private let redeploy: (DockerStack) -> Void
    @ObservationIgnored private var tasks: [EditableFile: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [EditableFile: Int] = [:]

    /// No side effects here: SwiftUI constructs `@State` defaults on every parent re-evaluation and discards extras.
    init(stack: DockerStack, server: Server, redeploy: @escaping (DockerStack) -> Void) {
        self.stack = stack
        self.serverName = server.name
        self.redeploy = redeploy
        files = StackFiles.editable(for: stack) ?? []
        session = StackFileSession(transport: makeTransport(for: server), policy: SafetyStore.shared.policy, stack: stack)
    }

    // MARK: reading

    func draft(_ file: EditableFile) -> Draft { drafts[file] ?? Draft() }

    func open(_ file: EditableFile) {
        let d = draft(file)
        guard d.original == nil, !d.loading else { return }
        load(file)
    }

    func load(_ file: EditableFile) {
        var d = draft(file)
        d.loading = true
        d.loadError = nil
        drafts[file] = d
        Task {
            var d = draft(file)
            do {
                let state = try await session.read(file)
                d.original = state
                d.text = state.content ?? ""
                d.loadError = state == .tooLarge ? StackFileError.tooLarge.errorDescription : nil
                d.validation = nil; d.validatedText = nil; d.checkError = nil; d.local = []
            } catch {
                d.loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            d.loading = false
            drafts[file] = d
        }
    }

    /// Throws away the draft and re-reads the file (after a conflict, or on request).
    func reload(_ file: EditableFile) {
        tasks[file]?.cancel()
        checking.remove(file)
        notice = nil
        var d = draft(file)
        d.original = nil
        drafts[file] = d
        load(file)
    }

    // MARK: editing

    func text(_ file: EditableFile) -> String { draft(file).text }

    func setText(_ file: EditableFile, _ text: String) {
        var d = draft(file)
        guard d.original != nil, d.text != text else { return }
        d.text = text
        d.local = file.isEnv ? EnvSyntax.check(text) : []
        drafts[file] = d
        notice = nil
        scheduleCheck(file)
    }

    func revert(_ file: EditableFile) {
        guard let original = draft(file).original else { return }
        setText(file, original.content ?? "")
    }

    func isDirty(_ file: EditableFile) -> Bool {
        let d = draft(file)
        guard let original = d.original, !d.loading else { return false }
        return d.text != (original.content ?? "")
    }

    var hasUnsavedChanges: Bool { files.contains(where: isDirty) }

    func changeCount(_ file: EditableFile) -> Int {
        let d = draft(file)
        return LineDiff.changeCount(old: d.original?.content ?? "", new: d.text)
    }

    func changedLines(_ file: EditableFile) -> Set<Int> {
        let d = draft(file)
        return LineDiff.changedLineNumbers(old: d.original?.content ?? "", new: d.text)
    }

    func errorLines(_ file: EditableFile) -> Set<Int> {
        let d = draft(file)
        guard isDirty(file) else { return [] }
        let server = d.validatedText == d.text ? (d.validation?.errors ?? []) : []
        return Set((d.local + server).filter { $0.severity == .error }.compactMap(\.line))
    }

    // MARK: checking

    private func scheduleCheck(_ file: EditableFile) {
        tasks[file]?.cancel()
        let generation = (generations[file] ?? 0) + 1
        generations[file] = generation
        var d = draft(file)
        guard isDirty(file) else {
            d.validation = nil; d.validatedText = nil; d.checkError = nil
            drafts[file] = d
            checking.remove(file)
            return
        }
        // A syntax error found locally needs no round trip.
        if !d.local.isEmpty {
            d.validation = nil; d.validatedText = nil; d.checkError = nil
            drafts[file] = d
            checking.remove(file)
            return
        }
        checking.insert(file)
        let text = d.text
        tasks[file] = Task {
            try? await Task.sleep(for: .milliseconds(600))   // wait for a pause in typing
            guard !Task.isCancelled else { return }
            var outcome: ValidationResult?
            var failure: String?
            do { outcome = try await session.validate(file, content: text) }
            catch { failure = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            // Only the newest check for this file may report.
            guard generations[file] == generation, !Task.isCancelled else { return }
            var d = draft(file)
            d.validation = outcome
            d.validatedText = outcome == nil ? nil : text
            d.checkError = failure
            drafts[file] = d
            checking.remove(file)
        }
    }

    /// The checklist under the editor (YAML syntax, schema, docker compose config; or .env syntax and the compose check).
    func rows(for file: EditableFile) -> [EditorCheckRow] {
        let d = draft(file)
        guard d.original != nil, isDirty(file) else { return [] }
        return EditorChecks.rows(isEnv: file.isEnv, serverName: serverName, local: d.local, checkError: d.checkError,
                                 validation: d.validation, validatedText: d.validatedText, text: d.text)
    }

    // MARK: saving

    /// Saving needs the current text to have passed the server check (and nothing after it to have changed).
    func canSave(_ file: EditableFile) -> Bool {
        let d = draft(file)
        guard isDirty(file), !saving, !SafetyStore.shared.readOnly, d.local.isEmpty,
              let validation = d.validation, d.validatedText == d.text, validation.isValid else { return false }
        return true
    }

    func canRedeploy(_ file: EditableFile) -> Bool {
        canSave(file) && ComposeAction.up.command(for: stack) != nil
    }

    func saveBlockedReason(_ file: EditableFile) -> String? {
        if SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if saving { return "Saving…" }
        if !isDirty(file) { return "No changes to save" }
        let d = draft(file)
        if !d.local.isEmpty { return "Fix the syntax error first" }
        if checking.contains(file) || d.validatedText != d.text { return d.checkError ?? "Waiting for the check on \(serverName)" }
        if d.validation?.isValid == false { return "Fix the errors above first" }
        return nil
    }

    func requestSave(_ file: EditableFile, redeploy: Bool) {
        guard canSave(file), !redeploy || canRedeploy(file) else { return }
        let d = draft(file)
        let edit = FileEdit(file: file, original: d.original?.content, originalSHA: d.original?.sha256, content: d.text)
        guard let intent = session.intent(for: edit) else { return }
        let name = file.fileName
        let upCommand = redeploy ? (ComposeAction.up.command(for: stack) ?? "") : ""
        pending = PendingAction(
            title: redeploy ? "Save \(name) and update \(stack.name)?" : "Save \(name)?",
            message: "The server checks it first, and nothing is written if that fails. The previous version is kept as \(name).rackoon.bak."
                + (redeploy ? " Then the stack is updated: containers whose image or settings changed are recreated." : ""),
            serverName: serverName, command: upCommand, destructive: false, preview: intent.preview,
            run: { [weak self] in self?.performSave(edit, redeploy: redeploy) })
    }

    private func performSave(_ edit: FileEdit, redeploy: Bool) {
        guard !saving else { return }
        saving = true
        notice = nil
        Task {
            defer { saving = false }
            do {
                let confirmation = try session.confirm(edit)
                switch try await session.save(edit, confirmation: confirmation) {
                case .saved(let sha):
                    var d = draft(edit.file)
                    let old: RemoteFile? = { if case .file(let f)? = d.original { return f }; return nil }()
                    d.original = .file(RemoteFile(content: edit.content, sha256: sha, mode: old?.mode ?? "600",
                                                  owner: old?.owner ?? "", modifiedAt: Int64(Date().timeIntervalSince1970)))
                    d.validation = nil; d.validatedText = nil
                    drafts[edit.file] = d
                    notice = .saved(file: edit.file.fileName, redeployed: redeploy)
                    if redeploy { self.redeploy(stack) }
                case .changedOnServer:
                    notice = .changedOnServer(edit.file)
                case .invalid(let issues):
                    var d = draft(edit.file)
                    d.validation = ValidationResult(issues: issues)
                    d.validatedText = edit.content
                    drafts[edit.file] = d
                }
            } catch {
                notice = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }
}
