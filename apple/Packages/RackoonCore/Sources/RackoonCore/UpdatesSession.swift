import Foundation

public struct UpdatesState: Sendable, Equatable {
    public var snapshot: UpdatesSnapshot?
    /// Why the last refresh failed. The last good snapshot stays beside it.
    public var error: String?
    public var updatedAt: Date?
    /// An apt action is running.
    public var isWorking = false
    /// Why the last apt action failed, until the next one starts.
    public var actionError: String?
    /// Tail of the last successful action's output, for a "done" message.
    public var actionOutput: String?
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
    private let policy: ActionPolicy
    public private(set) var state = UpdatesState()

    public init(transport: SSHTransport, policy: ActionPolicy = ActionPolicy()) {
        self.transport = transport
        self.policy = policy
    }

    public nonisolated func confirm(_ action: AptAction) throws -> Confirmation {
        guard let intent = action.intent else { throw PolicyError.invalidTarget }
        return try policy.confirm(intent)
    }

    /// Runs an apt action, then re-reads the update list. Ignored while another action is running.
    public func perform(_ action: AptAction, confirmation: Confirmation?) async {
        guard !state.isWorking else { return }
        guard let intent = action.intent else {
            state.actionError = "Refusing to run apt: invalid package name."
            return
        }
        do { try policy.authorize(intent, with: confirmation) } catch {
            state.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return
        }
        state.isWorking = true
        state.actionError = nil
        state.actionOutput = nil
        do {
            let result = try await transport.run(intent.command, timeout: action.timeout)
            if result.exitCode == 0 {
                state.actionOutput = result.stdout.split(separator: "\n").suffix(5).joined(separator: "\n")
            } else {
                state.actionError = AptAction.explain(stderr: result.stderr, exitCode: result.exitCode)
            }
        } catch {
            state.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        state.isWorking = false
        await refresh()
    }

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
