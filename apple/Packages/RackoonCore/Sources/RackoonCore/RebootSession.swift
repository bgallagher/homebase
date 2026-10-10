import Foundation

public enum RebootError: Error, LocalizedError, Equatable {
    case noSudo
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noSudo: "This user can't reboot the server without a password. Use root, or allow passwordless sudo for systemctl."
        case .failed(let m): m
        }
    }
}

public enum RebootOutcome: Sendable, Equatable {
    /// The server answered with a different boot id after `elapsed` seconds.
    case back(elapsed: TimeInterval)
    case timedOut
}

/// Reboots a server and waits for it to come back. "Back" means a different kernel boot id, not just a successful
/// connection: for a couple of seconds after the command, the old system still answers.
public actor RebootSession {
    public static let bootIDCommand = "cat /proc/sys/kernel/random/boot_id"
    public static let rebootCommand = #"if [ "$(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; $S true || { echo '##no-sudo'; exit 5; }; nohup sh -c "sleep 2; $S systemctl reboot" >/dev/null 2>&1 </dev/null & echo '##rebooting'"#

    private let transport: SSHTransport
    private let policy: ActionPolicy
    private var previousBootID: String?
    private var startedAt: Date?

    public init(transport: SSHTransport, policy: ActionPolicy = ActionPolicy()) {
        self.transport = transport
        self.policy = policy
    }

    public static var intent: Intent {
        Intent(summary: "Reboot the server", command: rebootCommand, risk: .mutate)
    }

    public nonisolated func confirm() throws -> Confirmation { try policy.confirm(Self.intent) }

    /// Remembers the current boot id, then schedules the reboot. Returns once the command has been accepted; the
    /// connection drops a couple of seconds later, so call `waitForReturn` next.
    public func reboot(confirmation: Confirmation?) async throws {
        try policy.authorize(Self.intent, with: confirmation)
        let before = try await transport.run(Self.bootIDCommand, timeout: 10)
        let id = before.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard before.exitCode == 0, !id.isEmpty else {
            throw RebootError.failed("Could not read the server's boot id first: \(before.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let result = try await transport.run(Self.rebootCommand, timeout: 15)
        if result.exitCode == 5 || result.stdout.contains("##no-sudo") { throw RebootError.noSudo }
        guard result.exitCode == 0, result.stdout.contains("##rebooting") else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RebootError.failed(detail.isEmpty ? "The reboot command failed (exit \(result.exitCode))." : detail)
        }
        previousBootID = id
        startedAt = Date()
    }

    /// Polls until the boot id differs from the one before the reboot. Connection errors are expected while the
    /// server is down and are simply retried. `now` and `sleep` can be replaced so tests do not wait.
    public func waitForReturn(timeout: TimeInterval = 600, interval: TimeInterval = 4,
                              now: @Sendable () -> Date = { Date() },
                              sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) async -> RebootOutcome {
        guard let previous = previousBootID, let start = startedAt else { return .timedOut }
        // The old system is still up for a moment; do not even ask until the reboot has had a chance to begin.
        await sleep(min(interval, 3))
        while now().timeIntervalSince(start) < timeout {
            if Task.isCancelled { return .timedOut }
            if let result = try? await transport.run(Self.bootIDCommand, timeout: 10), result.exitCode == 0 {
                let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, id != previous { return .back(elapsed: now().timeIntervalSince(start)) }
            }
            await sleep(interval)
        }
        return .timedOut
    }
}
