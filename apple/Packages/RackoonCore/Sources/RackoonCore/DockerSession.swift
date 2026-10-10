import Foundation

public enum DockerAction: String, Sendable, CaseIterable {
    case start, stop, restart

    /// What running this action on a container would do, for the policy and the confirmation dialog.
    public func intent(containerID: String) -> Intent? {
        guard let command = DockerSession.actionCommand(self, id: containerID) else { return nil }
        return Intent(summary: "\(rawValue.capitalized) container \(containerID)", command: command, risk: .mutate)
    }
}

/// Whole-stack actions, run with `docker compose` from the stack's own compose file.
public enum ComposeAction: String, Sendable, CaseIterable {
    case pull, up, restart, rebuild, recreate

    var commandID: String { "compose_\(rawValue)" }
    var template: String {
        switch self {
        case .pull: "cd {dir} && docker compose -p {project} {files} pull"
        case .up: "cd {dir} && docker compose -p {project} {files} up -d"
        case .restart: "cd {dir} && docker compose -p {project} {files} restart"
        case .rebuild: "cd {dir} && docker compose -p {project} {files} up -d --build"
        case .recreate: "cd {dir} && docker compose -p {project} {files} up -d --force-recreate"
        }
    }
    var verb: String {
        switch self {
        case .pull: "Pull images for"
        case .up: "Update"
        case .restart: "Restart"
        case .rebuild: "Rebuild"
        case .recreate: "Recreate"
        }
    }
    /// Pulling downloads images but touches no running container, so it is the one non-destructive stack action.
    public var timeout: TimeInterval {
        switch self {
        case .pull: 900
        case .rebuild: 1800   // building images from source can be slow
        case .up, .restart, .recreate: 600
        }
    }

    /// Rebuilds one service only: `--no-deps` keeps its dependencies (databases and the like) untouched.
    static let rebuildServiceTemplate = "cd {dir} && docker compose -p {project} {files} up -d --build --no-deps {service}"
    static let rebuildServiceCommandID = "compose_rebuild_service"

    /// Compose service names: letters, digits, `.`, `_`, `-`, starting with a letter or digit. The name comes from a
    /// container label, so it is checked before it reaches a shell.
    static func isServiceName(_ name: String) -> Bool {
        guard name.count <= 64, let first = name.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// The exact command, or nil if the stack has no compose project/paths or any of them is unsafe to send.
    /// With `service`, only `.rebuild` has a command (that one service); every other action is whole-stack.
    public func command(for stack: DockerStack, service: String? = nil) -> String? {
        guard let service else { return Self.fill(template, stack: stack, extra: [:]) }
        guard self == .rebuild, Self.isServiceName(service), stack.containers.contains(where: { $0.service == service }) else { return nil }
        return Self.fill(Self.rebuildServiceTemplate, stack: stack, extra: ["service": service])
    }

    private static func fill(_ template: String, stack: DockerStack, extra: [String: String]) -> String? {
        let paths = stack.configFiles.isEmpty ? (stack.configFile.map { [$0] } ?? []) : stack.configFiles
        // A comma inside a real path would have been split by the label parser, leaving a non-absolute piece,
        // which quotePath refuses, so a mangled list never reaches the shell.
        let files = paths.compactMap(ShellQuote.quotePath)
        guard !stack.isStandalone, DockerSession.isComposeProjectName(stack.name),
              let dir = stack.workingDir.flatMap(ShellQuote.quotePath),
              !paths.isEmpty, files.count == paths.count else { return nil }
        return Template.fill(template, ["dir": dir, "project": stack.name,
                                        "files": files.map { "-f " + $0 }.joined(separator: " ")].merging(extra) { $1 })
    }

    public func intent(for stack: DockerStack, service: String? = nil) -> Intent? {
        guard let command = command(for: stack, service: service) else { return nil }
        let summary = service.map { "\(verb) service \($0) of \(stack.name)" } ?? "\(verb) stack \(stack.name)"
        return Intent(summary: summary, command: command, risk: .mutate)
    }
}

public struct DockerState: Sendable, Equatable {
    public var snapshot: DockerSnapshot?
    /// Why the last poll failed. The last good snapshot stays visible beside it.
    public var error: String?
    public var updatedAt: Date?
    /// Containers with an action in flight.
    public var busy: Set<String> = []
    /// Compose projects with a whole-stack action in flight. Keyed by name, not container id: `up -d` creates
    /// containers with new ids, and the poll keeps replacing the snapshot underneath a long action.
    public var busyStacks: Set<String> = []
    /// Why the last action failed, until the next action starts.
    public var actionError: String?
    public init() {}
}

/// Polls `docker ps` and `docker stats` for one server and runs start, stop and restart.
/// Separate from ServerSession because `docker stats` takes about 2 s, so it polls more slowly
/// and only while the Docker screen is open.
public actor DockerSession {
    public static let command = """
    echo '##docker'; if command -v docker >/dev/null 2>&1; then echo ok; else echo missing; fi; \
    echo '##ps'; docker ps -a --format '{{json .}}' 2>&1; \
    echo '##stats'; docker stats --no-stream --format '{{json .}}' 2>&1
    """

    /// Container ids come from docker, but we still refuse anything that is not a hex id before it reaches a shell.
    public static func actionCommand(_ action: DockerAction, id: String) -> String? {
        guard isContainerID(id) else { return nil }
        return "docker \(action.rawValue) \(id)"
    }

    /// An interactive shell inside a container, for a terminal tab (`ssh -t host <this>`). Prefers bash, falls back to sh.
    public static func shellCommand(id: String) -> String? {
        isContainerID(id)
            ? "docker exec -it \(id) sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'" : nil
    }

    /// Follow a container's logs (last 100 lines first). Same id validation as actions.
    public static func logsCommand(id: String) -> String? {
        isContainerID(id) ? "docker logs -f --tail 100 \(id)" : nil
    }

    /// Compose project names are lowercase letters, digits, `-` and `_`, starting with a letter or digit.
    static func isComposeProjectName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase || first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isContainerID(_ id: String) -> Bool {
        id.count >= 12 && id.count <= 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private let transport: SSHTransport
    private let interval: TimeInterval
    private let policy: ActionPolicy
    public private(set) var state = DockerState()
    private var loop: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<DockerState>.Continuation] = [:]

    public init(transport: SSHTransport, interval: TimeInterval = 10, policy: ActionPolicy = ActionPolicy()) {
        self.transport = transport
        self.interval = interval
        self.policy = policy
    }

    public func updates() -> AsyncStream<DockerState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DockerState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        continuation.yield(state)
        return stream
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64((self?.interval ?? 10) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func refresh() async {
        do {
            let result = try await transport.run(Self.command, timeout: 20)
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SessionError.commandFailed(code: result.exitCode, detail: detail)
            }
            var next = state
            next.snapshot = try DockerParser.parse(result.stdout)
            next.error = nil
            next.updatedAt = Date()
            publish(next)
        } catch {
            var next = state
            next.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            publish(next)
        }
    }

    /// Call after the user has agreed (or straight away for actions the UI treats as low-risk).
    public nonisolated func confirm(_ action: DockerAction, containerID: String) throws -> Confirmation {
        guard let intent = action.intent(containerID: containerID) else { throw PolicyError.invalidTarget }
        return try policy.confirm(intent)
    }

    public nonisolated func confirm(_ action: ComposeAction, stack: DockerStack, service: String? = nil) throws -> Confirmation {
        guard let intent = action.intent(for: stack, service: service) else { throw PolicyError.invalidTarget }
        return try policy.confirm(intent)
    }

    /// Runs a whole-stack compose action, then refreshes. All the stack's containers show as busy meanwhile.
    public func perform(_ action: ComposeAction, stack: DockerStack, confirmation: Confirmation?) async {
        guard let intent = action.intent(for: stack) else {
            var next = state
            next.actionError = "Refusing to \(action.rawValue) \(stack.name): it has no usable compose project."
            publish(next)
            return
        }
        do {
            try policy.authorize(intent, with: confirmation)
        } catch {
            var next = state
            next.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            publish(next)
            return
        }
        let ids = Set(stack.containers.map(\.id))
        var working = state
        working.busy.formUnion(ids)
        working.busyStacks.insert(stack.name)
        working.actionError = nil
        publish(working)

        var failure: String?
        do {
            let result = try await transport.run(intent.command, timeout: action.timeout)
            if result.exitCode != 0 {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                // Compose writes progress to stderr too; the last lines carry the reason.
                let tail = detail.split(separator: "\n").suffix(3).joined(separator: "\n")
                failure = tail.isEmpty ? "docker compose \(action.rawValue) failed (exit \(result.exitCode))" : tail
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }

        var done = state
        done.busy.subtract(ids)
        done.busyStacks.remove(stack.name)
        done.actionError = failure
        publish(done)
        await refresh()
    }

    /// Runs a whole-stack compose action with live output and then refreshes. The command is the same one `perform`
    /// runs; only the way it is run differs (a pty, so compose draws its normal progress, and an exit-code marker).
    /// Cancelling the calling task stops the remote command (Ctrl-C through the pty).
    public func performStreaming(_ action: ComposeAction, stack: DockerStack, service: String? = nil, confirmation: Confirmation?,
                                 cols: Int, rows: Int, onEvent: @escaping @Sendable (ActionStreamEvent) -> Void) async {
        guard let intent = action.intent(for: stack, service: service) else {
            var next = state
            next.actionError = "Refusing to \(action.rawValue) \(stack.name): it has no usable compose project."
            publish(next)
            onEvent(.finished(exitCode: nil))
            return
        }
        let scoped = service == nil ? stack.containers : stack.containers.filter { $0.service == service }
        await stream(intent, confirmation: confirmation, ids: Set(scoped.map(\.id)), stackName: stack.name,
                     label: "docker compose \(action.rawValue)", cols: cols, rows: rows, onEvent: onEvent)
    }

    /// The same for one container's start, stop or restart, so every action shows up in the same live output.
    public func performStreaming(_ action: DockerAction, containerID: String, confirmation: Confirmation?,
                                 cols: Int, rows: Int, onEvent: @escaping @Sendable (ActionStreamEvent) -> Void) async {
        guard let intent = action.intent(containerID: containerID) else {
            var next = state
            next.actionError = "Refusing to run \(action.rawValue): invalid container id."
            publish(next)
            onEvent(.finished(exitCode: nil))
            return
        }
        await stream(intent, confirmation: confirmation, ids: [containerID], stackName: nil,
                     label: "docker \(action.rawValue)", cols: cols, rows: rows, onEvent: onEvent)
    }

    private func stream(_ intent: Intent, confirmation: Confirmation?, ids: Set<String>, stackName: String?, label: String,
                        cols: Int, rows: Int, onEvent: @escaping @Sendable (ActionStreamEvent) -> Void) async {
        do { try policy.authorize(intent, with: confirmation) } catch {
            var next = state
            next.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            publish(next)
            onEvent(.finished(exitCode: nil))
            return
        }
        var working = state
        working.busy.formUnion(ids)
        if let stackName { working.busyStacks.insert(stackName) }
        working.actionError = nil
        publish(working)

        let run = await StreamRunner.run(transport: transport, command: intent.command, cols: cols, rows: rows, onEvent: onEvent)
        let failure = run.failureMessage(label: label)

        var done = state
        done.busy.subtract(ids)
        if let stackName { done.busyStacks.remove(stackName) }
        done.actionError = failure
        publish(done)
        await refresh()
    }

    /// Runs the action, then refreshes so the list shows the result.
    public func perform(_ action: DockerAction, containerID: String, confirmation: Confirmation?) async {
        guard let intent = action.intent(containerID: containerID) else {
            var next = state
            next.actionError = "Refusing to run \(action.rawValue): invalid container id."
            publish(next)
            return
        }
        do {
            try policy.authorize(intent, with: confirmation)
        } catch {
            var next = state
            next.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            publish(next)
            return
        }
        let command = intent.command
        var working = state
        working.busy.insert(containerID)
        working.actionError = nil
        publish(working)

        var failure: String?
        do {
            let result = try await transport.run(command, timeout: 60)
            if result.exitCode != 0 {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                failure = detail.isEmpty ? "docker \(action.rawValue) failed (exit \(result.exitCode))" : detail
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }

        var done = state
        done.busy.remove(containerID)
        done.actionError = failure
        publish(done)
        await refresh()
    }

    private func publish(_ next: DockerState) {
        state = next
        for c in continuations.values { c.yield(next) }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
}
