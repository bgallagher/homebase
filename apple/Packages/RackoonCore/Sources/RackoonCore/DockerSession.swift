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
    case pull, up, recreate

    var commandID: String { "compose_\(rawValue)" }
    var template: String {
        switch self {
        case .pull: "cd {dir} && docker compose -p {project} {files} pull"
        case .up: "cd {dir} && docker compose -p {project} {files} up -d"
        case .recreate: "cd {dir} && docker compose -p {project} {files} up -d --force-recreate"
        }
    }
    var verb: String {
        switch self {
        case .pull: "Pull images for"
        case .up: "Update"
        case .recreate: "Recreate"
        }
    }
    /// Pulling downloads images but touches no running container, so it is the one non-destructive stack action.
    public var timeout: TimeInterval { self == .pull ? 900 : 600 }

    /// The exact command, or nil if the stack has no compose project/paths or any of them is unsafe to send.
    public func command(for stack: DockerStack) -> String? {
        let paths = stack.configFiles.isEmpty ? (stack.configFile.map { [$0] } ?? []) : stack.configFiles
        // A comma inside a real path would have been split by the label parser, leaving a non-absolute piece,
        // which quotePath refuses, so a mangled list never reaches the shell.
        let files = paths.compactMap(ShellQuote.quotePath)
        guard !stack.isStandalone, DockerSession.isComposeProjectName(stack.name),
              let dir = stack.workingDir.flatMap(ShellQuote.quotePath),
              !paths.isEmpty, files.count == paths.count else { return nil }
        return template
            .replacingOccurrences(of: "{dir}", with: dir)
            .replacingOccurrences(of: "{project}", with: stack.name)
            .replacingOccurrences(of: "{files}", with: files.map { "-f " + $0 }.joined(separator: " "))
    }

    public func intent(for stack: DockerStack) -> Intent? {
        guard let command = command(for: stack) else { return nil }
        return Intent(summary: "\(verb) stack \(stack.name)", command: command, risk: .mutate)
    }
}

public struct DockerState: Sendable, Equatable {
    public var snapshot: DockerSnapshot?
    /// Why the last poll failed. The last good snapshot stays visible beside it.
    public var error: String?
    public var updatedAt: Date?
    /// Containers with an action in flight.
    public var busy: Set<String> = []
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

    public nonisolated func confirm(_ action: ComposeAction, stack: DockerStack) throws -> Confirmation {
        guard let intent = action.intent(for: stack) else { throw PolicyError.invalidTarget }
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
