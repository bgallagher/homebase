import Foundation

public enum DockerAction: String, Sendable, CaseIterable {
    case start, stop, restart
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

    static func isContainerID(_ id: String) -> Bool {
        id.count >= 12 && id.count <= 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private let transport: SSHTransport
    private let interval: TimeInterval
    public private(set) var state = DockerState()
    private var loop: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<DockerState>.Continuation] = [:]

    public init(transport: SSHTransport, interval: TimeInterval = 10) {
        self.transport = transport
        self.interval = interval
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

    /// Runs the action, then refreshes so the list shows the result.
    public func perform(_ action: DockerAction, containerID: String) async {
        guard let command = Self.actionCommand(action, id: containerID) else {
            var next = state
            next.actionError = "Refusing to run \(action.rawValue): invalid container id."
            publish(next)
            return
        }
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
