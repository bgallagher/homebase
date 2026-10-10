import Foundation

public struct UpdatesState: Sendable, Equatable {
    public var snapshot: UpdatesSnapshot?
    /// Why the last refresh failed. The last good snapshot stays beside it.
    public var error: String?
    public var updatedAt: Date?
    public init() {}
}

/// Reads one server's pending apt updates. Read-only: it reports what apt already knows from its cache
/// and never refreshes it or installs anything (that needs root and goes through `ActionPolicy`).
public actor UpdatesSession {
    public static let command = """
    echo '##apt'; if command -v apt-get >/dev/null 2>&1; then echo ok; else echo missing; fi; \
    echo '##upgradable'; apt list --upgradable 2>/dev/null; \
    echo '##held'; apt-mark showhold 2>/dev/null; \
    echo '##refreshed'; stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || stat -c %Y /var/lib/apt/lists 2>/dev/null; \
    echo '##reboot'; if [ -f /var/run/reboot-required ]; then echo yes; else echo no; fi
    """

    private let transport: SSHTransport
    public private(set) var state = UpdatesState()

    public init(transport: SSHTransport) { self.transport = transport }

    @discardableResult
    public func refresh() async -> UpdatesState {
        do {
            let result = try await transport.run(Self.command, timeout: 20)
            // The command ends with a conditional that always succeeds, so a non-zero exit means ssh itself failed.
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdatesFailure(detail.isEmpty ? "ssh exited \(result.exitCode)" : detail)
            }
            state.snapshot = try UpdatesParser.parse(result.stdout)
            state.error = nil
            state.updatedAt = Date()
        } catch UpdatesParseError.notInstalled {
            state.error = "apt is not installed on this server."
        } catch {
            state.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        return state
    }

    private struct UpdatesFailure: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
