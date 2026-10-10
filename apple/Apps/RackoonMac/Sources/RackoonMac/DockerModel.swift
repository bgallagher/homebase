import Foundation
import RackoonCore
import RackoonSSHSystem
import Observation

/// Bridges DockerSession and the log stream to SwiftUI. Lives only while the Docker screen is open,
/// so `docker stats` is not polled in the background.
@MainActor @Observable
final class DockerModel {
    private(set) var state = DockerState()
    /// Lines shown in the panel. Updated at most ~10 times a second so a chatty container cannot
    /// make the UI re-render (and re-colour 2000 lines) on every chunk.
    private(set) var logLines: [String] = []
    @ObservationIgnored private var logBuffer = LogBuffer()
    @ObservationIgnored private var flushScheduled = false
    /// Everything received so far, for the Copy button.
    var logText: String { logBuffer.text }
    private(set) var logTarget: DockerContainer?
    private(set) var logsLive = false
    private(set) var logError: String?

    /// A stop or restart waiting for the user's yes (shown as a sheet by the Docker screen).
    var pending: PendingAction?
    /// A whole-stack compose action is running (they take minutes), e.g. "Pulling images for media…".
    private(set) var composeWorking: String?
    /// The most recent stack action and everything it printed, kept until dismissed or replaced by the next one.
    private(set) var output: ActionOutput?
    /// Stacks created from this app that have no containers yet. `docker ps` can't see them, so they are remembered
    /// here (for this run of the app) until their containers show up in the snapshot.
    private(set) var createdStacks: [String: DockerStack] = [:]
    /// The stack the user is deciding to delete (shown as a sheet by the Docker screen).
    var deleting: DockerStack?
    /// Stacks being deleted right now, kept visible (their containers vanish from `docker ps` before the run ends).
    private(set) var removing: [String: DockerStack] = [:]
    /// Set when a delete finished successfully, so the screen can leave the stack's page.
    private(set) var removedStack: String?
    @ObservationIgnored private let serverName: String
    @ObservationIgnored private let serverUser: String?
    @ObservationIgnored private let session: DockerSession
    @ObservationIgnored private let transport: SSHTransport
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    /// Bumped on every open/close so a stream that was cancelled cannot touch the next one's state.
    @ObservationIgnored private var logGeneration = 0

    init(server: Server) {
        let transport = OpenSSHTransport(server: server)
        self.transport = transport
        serverName = server.name
        serverUser = server.user
        session = DockerSession(transport: transport, policy: SafetyStore.shared.policy)
    }

    /// Every stack to show: the ones docker reports, then freshly created ones that have no containers yet.
    var stacks: [DockerStack] {
        let reported = state.snapshot?.stacks ?? []
        let names = Set(reported.map(\.name))
        let extra = createdStacks.merging(removing) { $1 }.values.filter { !names.contains($0.name) }.sorted { $0.name < $1.name }
        return reported + extra
    }

    func stack(named name: String) -> DockerStack? { stacks.first { $0.name == name } }

    /// Where a new stack should go by default: where this server's existing stacks live.
    var suggestedStackFolder: String {
        NewStackDefaults.parentDirectory(stacks: state.snapshot?.stacks ?? [], user: serverUser)
    }

    func adopt(_ stack: DockerStack) { createdStacks[stack.name] = stack }

    func start() {
        guard listener == nil else { return }
        let session = session
        listener = Task { [weak self] in
            for await next in await session.updates() { self?.state = next }
        }
        Task { await session.start() }
    }

    func stop() {
        closeLogs()
        listener?.cancel(); listener = nil
        let session = session
        Task { await session.stop() }
    }

    func refresh() {
        let session = session
        Task { await session.refresh() }
    }

    /// Stop and restart ask first, showing the exact command. Start runs straight away (it cannot break anything).
    /// Does nothing in read-only mode; the buttons are disabled then, and the session would refuse anyway.
    func request(_ action: DockerAction, on container: DockerContainer) {
        guard !SafetyStore.shared.readOnly else { return }
        guard action != .start else { perform(action, on: container); return }
        guard let intent = action.intent(containerID: container.id) else { return }
        let stopping = action == .stop
        pending = PendingAction(
            title: "\(stopping ? "Stop" : "Restart") \(container.name)?",
            message: stopping ? "\(container.name) will stop until you start it again."
                              : "\(container.name) will be restarted. Connections to it drop for a moment.",
            serverName: serverName, command: intent.command,
            destructive: stopping,
            run: { [weak self] in self?.perform(action, on: container) })
    }

    /// Why the stack's actions are unavailable, or nil if they can run.
    func composeBlockedReason(for stack: DockerStack) -> String? {
        if SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if composeWorking != nil { return "Another stack action is running" }
        if ComposeAction.up.command(for: stack) == nil {
            return stack.isStandalone ? "These containers were not started with Docker Compose"
                                      : "No single compose file was found for this stack"
        }
        return nil
    }

    /// Pull, update and recreate ask first, showing the exact command (one `docker compose` line for the whole stack).
    func request(_ action: ComposeAction, on stack: DockerStack) {
        guard composeBlockedReason(for: stack) == nil, let intent = action.intent(for: stack) else { return }
        let n = stack.containers.count
        let (title, message, working): (String, String, String) = switch action {
        case .pull:
            ("Pull images for \(stack.name)?",
             "Downloads newer images for the stack. Running containers are not touched; use Update afterwards to switch to them.",
             "Pulling images for \(stack.name)…")
        case .up:
            ("Update \(stack.name)?",
             "Recreates only the containers whose image or settings changed, and starts any that are stopped.",
             "Updating \(stack.name)…")
        case .restart:
            ("Restart all \(n) container\(n == 1 ? "" : "s") in \(stack.name)?",
             "Restarts the containers in place. They are not recreated, so image and settings changes are not applied; use Update for that.",
             "Restarting \(stack.name)…")
        case .rebuild:
            ("Rebuild \(stack.name)?",
             "Rebuilds images from the stack's Dockerfiles (services with a build section), then recreates the containers that changed. Services that only use pulled images are left alone. Building can take a while.",
             "Rebuilding \(stack.name)…")
        case .recreate:
            ("Recreate all \(n) container\(n == 1 ? "" : "s") in \(stack.name)?",
             "Every container is stopped and recreated from the compose file. Volumes are kept, but anything stored only inside a container is lost.",
             "Recreating \(stack.name)…")
        }
        pending = PendingAction(title: title, message: message, serverName: serverName, command: intent.command,
                                destructive: action == .recreate,
                                run: { [weak self] in self?.run(action, on: stack, label: working) })
    }

    /// Rebuilds one service of the stack (`up -d --build --no-deps <service>`), after asking with the exact command.
    func requestRebuild(of container: DockerContainer, in stack: DockerStack) {
        guard composeBlockedReason(for: stack) == nil, let service = container.service,
              let intent = ComposeAction.rebuild.intent(for: stack, service: service) else { return }
        pending = PendingAction(
            title: "Rebuild \(service)?",
            message: "Rebuilds the image for \(service) from its Dockerfile and recreates its container if the image changed. Other services in \(stack.name) are left alone. Building can take a while. If \(service) has no build section, nothing is rebuilt.",
            serverName: serverName, command: intent.command, destructive: false,
            run: { [weak self] in self?.run(.rebuild, on: stack, service: service, label: "Rebuilding \(service)…") })
    }

    /// Whether the Rebuild link applies to this container: it needs a compose service the stack can address.
    func canRebuild(_ container: DockerContainer, in stack: DockerStack) -> Bool {
        container.service.map { ComposeAction.rebuild.command(for: stack, service: $0) != nil } ?? false
    }

    func requestDelete(_ stack: DockerStack) {
        guard composeBlockedReason(for: stack) == nil else { return }
        deleting = stack
    }

    /// Deletes a stack after the sheet's confirmation, with the output in the stack's Output tab. On success the stack is
    /// forgotten and the screen is told to leave its page.
    func delete(_ stack: DockerStack, _ removal: StackRemoval) {
        guard composeWorking == nil else { return }
        composeWorking = "Deleting \(stack.name)…"
        removing[stack.name] = stack
        removedStack = nil
        let session = session
        output = ActionOutput.launch(
            scope: stack.name, title: "docker compose down",
            work: { cols, rows, onEvent in
                let confirmation = try? session.confirm(removal, stack: stack)
                await session.performStreaming(removal, stack: stack, confirmation: confirmation, cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in
                guard let self else { return }
                self.composeWorking = nil
                self.removing[stack.name] = nil
                if self.output?.phase == .succeeded {
                    self.createdStacks[stack.name] = nil
                    self.removedStack = stack.name
                }
            })
    }

    /// Runs a stack action without its own confirmation sheet, for flows where the user already agreed to it as part
    /// of a larger confirmed step (Save and redeploy). The policy still applies: read-only mode refuses it.
    func runDirect(_ action: ComposeAction, on stack: DockerStack) {
        guard composeBlockedReason(for: stack) == nil else { return }
        run(action, on: stack, label: "Updating \(stack.name)…")
    }

    /// Runs a stack action with its output streamed into `output`, which the detail page shows as a live terminal.
    private func run(_ action: ComposeAction, on stack: DockerStack, service: String? = nil, label: String) {
        guard composeWorking == nil else { return }
        composeWorking = label
        let session = session
        output = ActionOutput.launch(
            scope: stack.name, title: "docker compose \(action.rawValue)" + (service.map { " \($0)" } ?? ""),
            work: { cols, rows, onEvent in
                let confirmation = try? session.confirm(action, stack: stack, service: service)
                await session.performStreaming(action, stack: stack, service: service, confirmation: confirmation,
                                               cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in self?.composeWorking = nil })
    }

    /// Stops the running action (Ctrl-C reaches the command on the server).
    func cancelOutput() { output?.task?.cancel() }

    func dismissOutput() {
        guard output?.isRunning != true else { return }
        output = nil
    }

    /// Start, stop or restart one container, with its output in the same live Output tab as the stack actions.
    func perform(_ action: DockerAction, on container: DockerContainer) {
        guard composeWorking == nil else { return }
        composeWorking = "\(action.rawValue.capitalized) \(container.name)…"
        let session = session
        output = ActionOutput.launch(
            scope: container.project ?? "Standalone", title: "docker \(action.rawValue) \(container.name)",
            intro: "\u{1B}[2m$ docker \(action.rawValue) \(container.name)\u{1B}[0m\r\n",
            work: { cols, rows, onEvent in
                let confirmation = try? session.confirm(action, containerID: container.id)
                await session.performStreaming(action, containerID: container.id, confirmation: confirmation,
                                               cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in self?.composeWorking = nil })
    }

    /// Clicking the container that is already open closes its logs.
    func toggleLogs(for container: DockerContainer) {
        if logTarget?.id == container.id { closeLogs() } else { showLogs(for: container) }
    }

    func showLogs(for container: DockerContainer) {
        guard logTarget?.id != container.id else { return }
        closeLogs()
        guard let command = DockerSession.logsCommand(id: container.id) else { return }
        logTarget = container
        logBuffer = LogBuffer()
        logLines = []
        logError = nil
        logsLive = true
        let generation = logGeneration
        let transport = transport
        logTask = Task { [weak self] in
            do {
                for try await chunk in transport.stream(command) {
                    guard let self, self.logGeneration == generation else { return }
                    self.logBuffer.append(chunk)
                    self.scheduleFlush(generation)
                }
            } catch {
                guard let self, self.logGeneration == generation else { return }
                self.logError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            guard let self, self.logGeneration == generation else { return }
            self.logsLive = false
        }
    }

    private func scheduleFlush(_ generation: Int) {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.flushScheduled = false
            if self.logGeneration == generation { self.logLines = self.logBuffer.lines }
        }
    }

    func closeLogs() {
        logGeneration += 1
        logTask?.cancel(); logTask = nil   // cancelling sends Ctrl-C to the remote `docker logs -f`
        logTarget = nil
        logLines = []
        logsLive = false
    }
}
