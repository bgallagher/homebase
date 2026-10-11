import Foundation
import RackoonCore
import RackoonSSHSystem

/// State of the Add container page: the form (a `ContainerSpec`), the compose.yaml and .env it produces, the server-side
/// checks of those, and writing them. Checks change nothing on the server; writing asks first.
@MainActor @Observable
final class AddContainerModel {
    enum Target { case newStack, existing }
    enum Tab { case compose, env }

    /// What a finished add hands back to the Docker screen.
    struct Result { var stack: DockerStack; var isNew: Bool; var start: Bool }

    private struct ExistingFiles {
        var compose: RemoteFileState?
        var env: RemoteFileState?
        var error: String?
    }

    var spec = ContainerSpec()
    private(set) var target: Target = .newStack
    var tab: Tab = .compose
    var stackName = ""
    var folder: String
    private(set) var existingName: String?
    private(set) var composeOverride: String?
    private(set) var envOverride: String?
    private(set) var validation: ValidationResult?
    private(set) var checkError: String?
    private(set) var imageStatus: ImageStatus?
    private(set) var listening: Set<Int>?
    private(set) var creating = false
    var notice: String?
    var pending: PendingAction?
    @ObservationIgnored let serverName: String
    @ObservationIgnored private let transport: SSHTransport
    @ObservationIgnored private let policy: ActionPolicy
    // The Docker screen that is showing this page right now. They are replaced by `attach` each time the screen is
    // rebuilt (switching to Terminal and back), so the draft keeps working with the new screen's data.
    @ObservationIgnored private var stacksNow: () -> [DockerStack] = { [] }
    @ObservationIgnored private var containersNow: () -> [DockerContainer] = { [] }
    @ObservationIgnored private var blockedReason: (DockerStack) -> String? = { _ in nil }
    @ObservationIgnored private var finished: (Result) -> Void = { _ in }
    @ObservationIgnored private let newSession: NewStackSession
    @ObservationIgnored private let checker: ContainerChecker
    @ObservationIgnored private var fileSession: StackFileSession?
    private var existing: ExistingFiles?
    @ObservationIgnored private var validatedKey: String?
    @ObservationIgnored private var imageFor: String?
    @ObservationIgnored private var portsFor: [Int] = []
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    @ObservationIgnored private var portsTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// What the last read of the hand-edited compose text put into the form, and whether the form can show all of it.
    @ObservationIgnored private var reflectedSpec: ContainerSpec?
    private var reflectedLossless = false
    /// Set while the pasted file defines several services: the form can't edit that, but it shows what is in the file.
    private(set) var servicesInFile: ComposeFormParser.Overview?
    /// The stack name this page filled in from the file's `name:`, so a later paste can replace it but a typed name is kept.
    @ObservationIgnored private var autoStackName: String?

    /// No side effects here: SwiftUI may construct this more than once. `start()` begins the checks.
    init(server: Server, folder: String) {
        let transport = makeTransport(for: server)
        self.transport = transport
        policy = SafetyStore.shared.policy
        serverName = server.name
        self.folder = folder
        newSession = NewStackSession(transport: transport, policy: SafetyStore.shared.policy)
        checker = ContainerChecker(transport: transport)
    }

    func attach(stacks: @escaping () -> [DockerStack], containers: @escaping () -> [DockerContainer],
                blockedReason: @escaping (DockerStack) -> String?, finished: @escaping (Result) -> Void) {
        stacksNow = stacks
        containersNow = containers
        self.blockedReason = blockedReason
        self.finished = finished
    }

    // MARK: choosing where it goes

    var existingCandidates: [DockerStack] {
        stacksNow().filter { !$0.isStandalone && StackFiles.editable(for: $0) != nil }
    }

    private var existingStack: DockerStack? { existingName.flatMap { name in stacksNow().first { $0.name == name } } }

    /// Everything typed or pasted for a new stack, kept while the page shows the other target so switching back doesn't lose it.
    private struct NewStackDraft {
        var composeOverride: String?
        var envOverride: String?
        var spec: ContainerSpec
        var stackName: String
        var reflectedSpec: ContainerSpec?
        var reflectedLossless: Bool
        var servicesInFile: ComposeFormParser.Overview?
        var autoStackName: String?
    }
    @ObservationIgnored private var newStackDraft: NewStackDraft?

    func setTarget(_ new: Target) {
        guard new != target else { return }
        if target == .newStack {
            newStackDraft = NewStackDraft(composeOverride: composeOverride, envOverride: envOverride, spec: spec, stackName: stackName,
                                          reflectedSpec: reflectedSpec, reflectedLossless: reflectedLossless,
                                          servicesInFile: servicesInFile, autoStackName: autoStackName)
        }
        target = new
        composeOverride = nil; envOverride = nil
        if new == .newStack, let draft = newStackDraft {
            composeOverride = draft.composeOverride; envOverride = draft.envOverride
            spec = draft.spec; stackName = draft.stackName
            reflectedSpec = draft.reflectedSpec; reflectedLossless = draft.reflectedLossless
            servicesInFile = draft.servicesInFile; autoStackName = draft.autoStackName
            newStackDraft = nil
        } else if new == .existing {
            servicesInFile = nil   // the existing-stack page shows its own file, not the pasted one
        }
        notice = nil
        scheduleChecks()
    }

    /// Variables the compose file uses that `.env` doesn't set (from the server's own check of the current text).
    var missingVariables: [String] {
        guard validatedKey == key, let validation else { return [] }
        let defined = Set(EnvSyntax.names(in: envText))
        return validation.unsetVariables.filter { !defined.contains($0) }
    }

    /// Appends `NAME=` lines for the missing variables to `.env` and shows that tab, ready to be filled in.
    func addMissingVariables() {
        let missing = missingVariables
        guard !missing.isEmpty else { return }
        var text = envText
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += missing.map { "\($0)=" }.joined(separator: "\n") + "\n"
        tab = .env
        setText(text, for: .env)
    }

    func chooseExisting(_ name: String) {
        guard let stack = stacksNow().first(where: { $0.name == name }), StackFiles.editable(for: stack) != nil else { return }
        existingName = name
        existing = ExistingFiles()
        composeOverride = nil; envOverride = nil
        notice = nil
        fileSession = StackFileSession(transport: transport, policy: policy, stack: stack)
        scheduleChecks()
        guard let files = StackFiles.editable(for: stack), let compose = files.first, let env = files.last, let session = fileSession else { return }
        Task {
            var loaded = ExistingFiles()
            do {
                loaded.compose = try await session.read(compose)
                loaded.env = try await session.read(env)
            } catch { loaded.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            guard existingName == name else { return }
            existing = loaded
            scheduleChecks()
        }
    }

    // MARK: the files

    private var originalCompose: String? { existing?.compose?.content }
    private var originalEnv: String { existing?.env?.content ?? "" }
    private var existingReady: Bool { existing != nil && existing?.error == nil && originalCompose != nil }

    /// The compose file as the form (or a hand edit) has it. Until the form can produce YAML, a placeholder.
    private var generatedCompose: String {
        switch target {
        case .newStack:
            return spec.name.isEmpty || spec.nameProblem != nil || spec.image.isEmpty || spec.imageProblem != nil
                ? "services:\n  # Enter a container name and an image\n" : spec.composeText
        case .existing:
            guard let original = originalCompose else { return "" }
            guard spec.blockingProblem == nil else { return original }
            return (try? ComposeInsert.adding(spec, to: original)) ?? original
        }
    }

    private var generatedEnv: String {
        switch target {
        case .newStack: return spec.envProblemFree ? spec.envText : ""
        case .existing: return spec.envProblemFree ? EnvMerge.merge(existing: originalEnv, adding: spec.activeEnv).text : originalEnv
        }
    }

    var composeText: String { composeOverride ?? generatedCompose }
    var envText: String { envOverride ?? generatedEnv }

    var imageStatusValue: ImageStatus? { imageStatus }
    var newStackFolderProblem: String? { plan.folderProblem }
    var plannedDirectory: String { plan.directory ?? "\(folder)/\(stackName.isEmpty ? "<name>" : stackName)" }

    func text(_ tab: Tab) -> String { tab == .compose ? composeText : envText }

    func setText(_ value: String, for tab: Tab) {
        switch tab {
        case .compose:
            composeOverride = value == generatedCompose ? nil : value
            if composeOverride != nil, target == .newStack { reflectIntoForm(value) }
        case .env: envOverride = value == generatedEnv ? nil : value
        }
        notice = nil
        scheduleChecks()
    }

    /// Typed or pasted compose text fills the form in (like Dockge). The text stays as written; the form is a read-out
    /// until it is edited, and if the file uses things the form can't show, it stays a read-out (`formLocked`).
    private func reflectIntoForm(_ text: String) {
        let overview = ComposeFormParser.overview(of: text)
        // A compose project `name:` is a good stack name: fill it in unless the user typed their own.
        if let project = overview.projectName, NewStackPlan(name: project, parentDirectory: folder, compose: "", env: "").nameProblem == nil,
           stackName.isEmpty || stackName == autoStackName {
            stackName = project
            autoStackName = project
        }
        if let parsed = ComposeFormParser.parse(text, env: envText) {
            spec = parsed.spec
            reflectedSpec = parsed.spec
            reflectedLossless = parsed.lossless
            servicesInFile = nil
        } else {
            reflectedLossless = false
            servicesInFile = overview.services.isEmpty ? nil : overview
        }
    }

    /// True while the compose text has settings the form can't edit, so editing the form would lose them.
    var formLocked: Bool { target == .newStack && composeOverride != nil && !reflectedLossless }

    var isHandEdited: Bool { composeOverride != nil || envOverride != nil }

    func resetToForm() {
        composeOverride = nil; envOverride = nil; reflectedSpec = nil; servicesInFile = nil; newStackDraft = nil
        scheduleChecks()
    }

    /// Problem inserting into the chosen stack's compose file (a service of that name already exists, inline services).
    var insertProblem: String? {
        guard target == .existing, composeOverride == nil, existingReady, spec.blockingProblem == nil, let original = originalCompose else { return nil }
        do { _ = try ComposeInsert.adding(spec, to: original); return nil }
        catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    var fileCaption: String {
        switch target {
        case .newStack: "\(stackName.isEmpty ? "new-stack" : stackName) / compose.yaml (new) · edit any line"
        case .existing: "\(existingName ?? "…") / \(tab == .compose ? "compose.yaml" : ".env") · edit any line"
        }
    }

    /// Lines to band green: everything for a new file, the added lines for an existing one.
    func changedLines(_ tab: Tab) -> Set<Int> {
        let now = text(tab)
        switch target {
        case .newStack:
            let n = now.components(separatedBy: "\n").count - (now.hasSuffix("\n") ? 1 : 0)
            return n > 0 ? Set(1...n) : []
        case .existing:
            return LineDiff.changedLineNumbers(old: tab == .compose ? (originalCompose ?? "") : originalEnv, new: now)
        }
    }

    func errorLines(_ tab: Tab) -> Set<Int> {
        if tab == .env { return Set(EnvSyntax.check(envText).filter { $0.severity == .error }.compactMap(\.line)) }
        guard validatedKey == key else { return [] }
        return Set((validation?.errors ?? []).compactMap(\.line))
    }

    // MARK: checks

    private var plan: NewStackPlan { NewStackPlan(name: stackName, parentDirectory: folder, compose: composeText, env: envText) }
    private var key: String { [String(describing: target), stackName, existingName ?? "", composeText, envText].joined(separator: "\u{0}") }

    /// Why the compose file can't be checked yet, or nil.
    private var composeSkipReason: String? {
        if composeOverride == nil, let p = spec.blockingProblem { return p }
        switch target {
        case .newStack:
            if let p = plan.nameProblem { return stackName.isEmpty ? "Enter a stack name" : p }
            return plan.folderProblem
        case .existing:
            if existingName == nil { return "Choose a stack" }
            if let e = existing?.error { return e }
            return existingReady ? nil : "Reading the stack from \(serverName)…"
        }
    }

    func specChanged() {
        notice = nil
        if target == .newStack, composeOverride != nil {
            // The form just echoed a read of the text: nothing to do. A real form edit on a file the form fully
            // describes hands the file back to the form.
            if spec != reflectedSpec, reflectedLossless { composeOverride = nil }
        }
        scheduleChecks()
    }

    func start() {
        scheduleChecks()
    }

    private func scheduleChecks() {
        // Image and port lookups only rerun when what they look at changed.
        if spec.image != imageFor {
            imageTask?.cancel()
            imageFor = spec.image
            imageStatus = nil
            let image = spec.image
            if spec.imageProblem == nil, !image.isEmpty {
                imageTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    let status = await checker.imageStatus(image)
                    guard !Task.isCancelled, imageFor == image else { return }
                    imageStatus = status
                }
            }
        }
        let ports = spec.activePorts.compactMap(\.hostPort)
        if portsTask == nil || ports != portsFor {
            portsTask?.cancel()
            portsFor = ports
            listening = nil
            portsTask = Task {
                let found = await checker.listeningPorts()
                guard !Task.isCancelled, portsFor == ports else { return }
                listening = found ?? []
            }
        }
        checkTask?.cancel()
        generation += 1
        let mine = generation
        guard composeSkipReason == nil, EnvSyntax.check(envText).isEmpty else {
            validation = nil; validatedKey = nil; checkError = nil
            return
        }
        let snapshotKey = key, compose = composeText, plan = plan, target = target, stack = existingStack, session = fileSession
        validation = validatedKey == snapshotKey ? validation : nil
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(600))   // wait for a pause in typing
            guard !Task.isCancelled else { return }
            var outcome: ValidationResult?
            var failure: String?
            do {
                switch target {
                case .newStack:
                    outcome = try await newSession.check(plan)
                case .existing:
                    guard let stack, let session, let file = StackFiles.editable(for: stack)?.first else { return }
                    outcome = try await session.validate(file, content: compose)
                    // The new variables are not in the server's .env until we save, so compose warns about them; that is expected.
                    let added = Set(spec.activeEnv.map(\.key))
                    outcome?.issues.removeAll { issue in
                        issue.severity == .warning && added.contains { name in issue.message.contains("\"\(name)\"") }
                    }
                }
            } catch { failure = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            guard generation == mine, !Task.isCancelled else { return }
            validation = outcome
            validatedKey = outcome == nil ? nil : snapshotKey
            checkError = failure
        }
    }

    /// The checklist: compose result, image, each port, the container name.
    var rows: [EditorCheckRow] {
        var rows: [EditorCheckRow] = []
        if let reason = composeSkipReason {
            rows.append(EditorCheckRow(id: "yaml", state: .skipped, title: "YAML syntax", detail: reason))
        } else if let env = EnvSyntax.check(envText).first {
            rows.append(EditorCheckRow(id: "env", state: .fail, title: ".env syntax", detail: EditorChecks.describe(env)))
        } else {
            let k = key
            rows += ContainerChecks.composeRow(
                EditorChecks.rows(isEnv: false, serverName: serverName, local: [], checkError: checkError, validation: validation,
                                  validatedText: validatedKey == k ? k : nil, text: k), serverName: serverName)
        }
        if let problem = insertProblem { rows.append(EditorCheckRow(id: "insert", state: .fail, title: "Add to stack", detail: problem)) }
        if let file = servicesInFile {
            // The image, port and name checks are for the one-container form; the server's compose check above covers the file.
            let n = file.services.count
            rows.append(EditorCheckRow(id: "services", state: .skipped, title: "Services",
                                       detail: "\(n) services in this file: image and port checks cover the one-container form only"))
        } else {
            rows.append(ContainerChecks.imageRow(spec, status: imageStatus))
            rows += ContainerChecks.portRows(spec, listening: listening, containers: containersNow(), serverName: serverName)
            rows.append(ContainerChecks.nameRow(spec, stack: target == .newStack ? stackName : existingName, containers: containersNow()))
        }
        if target == .existing, spec.activeEnv.contains(where: { EnvMerge.merge(existing: originalEnv, adding: [$0]).kept.contains($0.key) }) {
            let kept = EnvMerge.merge(existing: originalEnv, adding: spec.activeEnv).kept.joined(separator: ", ")
            rows.append(EditorCheckRow(id: "envkept", state: .warn, title: "Already in .env", detail: "\(kept) keeps its current value"))
        }
        return rows
    }

    // MARK: writing

    var footnote: String {
        if let blocked = deployBlockedReason { return blocked }
        if isHandEdited { return "Edited by hand: changes in the form no longer update the files." }
        return "Checked on \(serverName) before anything is written."
    }

    var newStackNameProblem: String? {
        if stackName.isEmpty { return nil }
        if let p = plan.nameProblem { return p }
        return stacksNow().contains { $0.name == stackName } ? "A stack named \(stackName) already exists" : nil
    }

    var deployBlockedReason: String? {
        if SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if creating { return "Working…" }
        switch target {
        case .newStack:
            if stackName.isEmpty { return "Enter a stack name" }
            if let p = newStackNameProblem { return p }
            if let p = plan.folderProblem { return p }
        case .existing:
            if existingName == nil { return "Choose a stack to add the container to" }
            if let e = existing?.error { return e }
            if !existingReady { return "Reading the stack from \(serverName)…" }
        }
        if composeOverride == nil, let p = spec.blockingProblem { return p }
        if let p = insertProblem { return p }
        if let problem = EnvSyntax.check(envText).first { return "Fix .env: \(EditorChecks.describe(problem))" }
        let rows = rows
        if let bad = rows.first(where: { $0.state == .fail }) { return "\(bad.title): \(bad.detail)" }
        if rows.contains(where: { $0.state == .running }) || validatedKey != key { return checkError ?? "Waiting for the checks on \(serverName)" }
        if let stack = (target == .newStack ? plan.stack : existingStack), let reason = blockedReason(stack) { return reason }
        return nil
    }

    func request(start: Bool) {
        guard deployBlockedReason == nil else { return }
        switch target {
        case .newStack: requestNew(start: start)
        case .existing: requestExisting(start: start)
        }
    }

    private func requestNew(start: Bool) {
        let plan = plan
        guard let stack = plan.stack, let intent = newSession.intent(for: plan), let directory = plan.directory else { return }
        let up = start ? (ComposeAction.up.command(for: stack) ?? "") : ""
        pending = PendingAction(
            title: start ? "Create \(plan.name) and start it?" : "Create \(plan.name)?",
            message: "Creates \(directory) on \(serverName) with the files below. The server checks them first and removes everything it made if that fails."
                + (start ? " Then the stack is started with docker compose up -d, which pulls any images it needs." : ""),
            serverName: serverName, command: up, destructive: false, preview: intent.preview,
            run: { [weak self] in self?.performNew(plan, stack: stack, start: start) })
    }

    private func performNew(_ plan: NewStackPlan, stack: DockerStack, start: Bool) {
        guard !creating else { return }
        creating = true
        notice = nil
        Task {
            defer { creating = false }
            do {
                switch try await newSession.create(plan, confirmation: try newSession.confirm(plan)) {
                case .created: finished(Result(stack: stack, isNew: true, start: start))
                case .exists: notice = "\(stack.workingDir ?? plan.name) already exists on \(serverName), so nothing was written. Choose another name or folder."
                case .invalid(let issues):
                    validation = ValidationResult(issues: issues); validatedKey = key
                    notice = "\(serverName) refused the files, so nothing was created."
                }
            } catch { notice = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    private struct Edits { var compose: FileEdit; var env: FileEdit? }

    private func edits(for stack: DockerStack) -> Edits? {
        guard let files = StackFiles.editable(for: stack), let composeFile = files.first, let envFile = files.last,
              let existing, let original = existing.compose, case .file(let c) = original else { return nil }
        let compose = FileEdit(file: composeFile, original: c.content, originalSHA: c.sha256, content: composeText)
        var env: FileEdit?
        if envText != originalEnv {
            var oldContent: String?, oldSHA: String?
            if case .file(let e)? = existing.env { oldContent = e.content; oldSHA = e.sha256 }
            env = FileEdit(file: envFile, original: oldContent, originalSHA: oldSHA, content: envText)
        }
        return Edits(compose: compose, env: env)
    }

    private func requestExisting(start: Bool) {
        guard let stack = existingStack, let session = fileSession, let edits = edits(for: stack),
              let composeIntent = session.intent(for: edits.compose) else { return }
        var preview = "compose.yaml\n" + (composeIntent.preview ?? "")
        if let env = edits.env, let intent = session.intent(for: env) { preview += "\n\n.env\n" + (intent.preview ?? "") }
        let up = start ? (ComposeAction.up.command(for: stack) ?? "") : ""
        pending = PendingAction(
            title: start ? "Add \(spec.name) to \(stack.name) and start it?" : "Add \(spec.name) to \(stack.name)?",
            message: "The server checks each file first, and nothing is written if that fails. The previous versions are kept as .rackoon.bak."
                + (start ? " Then the stack is updated: the new container starts, and any container whose settings changed is recreated." : ""),
            serverName: serverName, command: up, destructive: false, preview: preview,
            run: { [weak self] in self?.performExisting(stack, edits: edits, session: session, start: start) })
    }

    private func performExisting(_ stack: DockerStack, edits: Edits, session: StackFileSession, start: Bool) {
        guard !creating else { return }
        creating = true
        notice = nil
        Task {
            defer { creating = false }
            do {
                // .env first: if the compose save is then refused, a spare variable is harmless; the other way round
                // would leave a service that refers to a variable that was never written.
                for edit in [edits.env, edits.compose].compactMap({ $0 }) {
                    switch try await session.save(edit, confirmation: try session.confirm(edit)) {
                    case .saved: continue
                    case .changedOnServer:
                        notice = "\(edit.file.fileName) changed on \(serverName) after you opened this page, so it was not saved. Go back and add the container again."
                        return
                    case .invalid(let issues):
                        validation = ValidationResult(issues: issues); validatedKey = key
                        notice = "\(serverName) refused \(edit.file.fileName), so it was not saved."
                        return
                    }
                }
                finished(Result(stack: stack, isNew: false, start: start))
            } catch { notice = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    var isDirty: Bool {
        !spec.name.isEmpty || !spec.image.isEmpty || !stackName.isEmpty || isHandEdited
            || !spec.activePorts.isEmpty || !spec.activeVolumes.isEmpty || !spec.activeEnv.isEmpty
    }
}

private extension ContainerSpec {
    /// True when the environment rows alone are fine to write (the rest of the form may still be incomplete).
    var envProblemFree: Bool {
        activeEnv.allSatisfy { ContainerSpec.envProblem($0) == nil } && Set(activeEnv.map(\.key)).count == activeEnv.count
    }
}
