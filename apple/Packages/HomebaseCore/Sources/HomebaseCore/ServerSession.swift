import Foundation

public struct ServerState: Sendable, Equatable {
    public var overview: Overview?
    public var cpuPercent: Double?
    public var attention: [AttentionItem] = []
    public var error: String?
    public var updatedAt: Date?
    public init() {}
}

/// Owns one server's transport and poll loop. Views never call SSH directly.
public actor ServerSession {
    public static let overviewCommand = """
    echo '##hostname'; hostname; echo '##os'; cat /etc/os-release; echo '##uptime'; cat /proc/uptime; \
    echo '##loadavg'; cat /proc/loadavg; echo '##nproc'; nproc; echo '##stat'; head -1 /proc/stat; \
    echo '##meminfo'; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; \
    echo '##df'; df -P -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null; \
    echo '##reboot'; if [ -f /var/run/reboot-required ]; then echo yes; else echo no; fi
    """

    private let transport: SSHTransport
    private let interval: TimeInterval
    public private(set) var state = ServerState()
    private var previous: Overview?
    private var loop: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<ServerState>.Continuation] = [:]

    public init(transport: SSHTransport, interval: TimeInterval = 5) {
        self.transport = transport
        self.interval = interval
    }

    /// Emits the current state immediately, then every refresh.
    public func updates() -> AsyncStream<ServerState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ServerState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(state)
        return stream
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64((self?.interval ?? 5) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One poll. Public so callers (and tests) can refresh on demand.
    public func refresh() async {
        do {
            let result = try await transport.run(Self.overviewCommand, timeout: 10)
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SessionError.commandFailed(code: result.exitCode, detail: detail)
            }
            let overview = try OverviewParser.parse(result.stdout)
            var next = state
            next.cpuPercent = previous.flatMap { overview.cpuPercent(since: $0) } ?? next.cpuPercent
            next.overview = overview
            next.attention = Attention.evaluate(overview)
            next.error = nil
            next.updatedAt = Date()
            previous = overview
            publish(next)
        } catch {
            // Keep the last good data on screen and surface the error beside it.
            var next = state
            next.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            publish(next)
        }
    }

    private func publish(_ next: ServerState) {
        state = next
        for c in continuations.values { c.yield(next) }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }
}

public enum SessionError: Error, LocalizedError {
    case commandFailed(code: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let detail):
            detail.isEmpty ? "Command failed (exit \(code))" : detail
        }
    }
}
