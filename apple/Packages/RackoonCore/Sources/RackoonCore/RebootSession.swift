import Foundation

public enum RebootError: Error, LocalizedError, Equatable {
    /// `sudo -n` was refused: the user needs a password for sudo. The app may ask for one and retry with `reboot(sudoPassword:)`.
    case noSudo
    /// The password given to `sudo -S` was not accepted. Nothing was scheduled.
    case badPassword
    /// sudo refused for another reason (not in sudoers, needs a terminal). Carries a readable explanation.
    case sudoRefused(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noSudo: "This user can't reboot the server without a password. Use root, or allow passwordless sudo for systemctl."
        case .badPassword: "The server did not accept that password."
        case .sudoRefused(let m): m
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
    /// The same reboot through `sudo -S`, which reads the password from standard input (the app writes it there and
    /// nowhere else; `-p ''` keeps sudo from printing a prompt). One sudo call does everything as root, so no second
    /// sudo has to run inside the delayed shell. sudo's own messages go to stdout so a refusal can be read.
    // Three hashes: the script itself contains `"##`, which would end a one- or two-hash raw string.
    public static let sudoRebootCommand = ###"sudo -S -p '' sh -c 'nohup sh -c "sleep 2; systemctl reboot" >/dev/null 2>&1 </dev/null & echo "##rebooting"' 2>&1 || { echo '##sudo-failed'; exit 6; }"###

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

    /// A separate intent, so a confirmation of the plain reboot never authorises the password one and vice versa.
    public static var sudoIntent: Intent {
        Intent(summary: "Reboot the server with sudo", command: sudoRebootCommand, risk: .mutate)
    }

    public nonisolated func confirm() throws -> Confirmation { try policy.confirm(Self.intent) }
    public nonisolated func confirmSudo() throws -> Confirmation { try policy.confirm(Self.sudoIntent) }

    /// Remembers the current boot id, then schedules the reboot. Returns once the command has been accepted; the
    /// connection drops a couple of seconds later, so call `waitForReturn` next.
    public func reboot(confirmation: Confirmation?) async throws {
        try policy.authorize(Self.intent, with: confirmation)
        let id = try await readBootID()
        let result = try await transport.run(Self.rebootCommand, timeout: 15)
        if result.exitCode == 5 || result.stdout.contains("##no-sudo") { throw RebootError.noSudo }
        guard result.exitCode == 0, result.stdout.contains("##rebooting") else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RebootError.failed(detail.isEmpty ? "The reboot command failed (exit \(result.exitCode))." : detail)
        }
        scheduled(before: id)
    }

    /// The same, for a user whose sudo wants a password: it is written to the command's standard input and is not kept.
    /// `.badPassword` means nothing happened and the user may try again.
    public func reboot(sudoPassword: String, confirmation: Confirmation?) async throws {
        try policy.authorize(Self.sudoIntent, with: confirmation)
        let id = try await readBootID()
        let result = try await transport.run(Self.sudoRebootCommand, input: sudoPassword + "\n", timeout: 20)
        guard result.exitCode == 0, result.stdout.contains("##rebooting") else {
            throw Self.classifySudoFailure(result.stdout + "\n" + result.stderr, exitCode: result.exitCode)
        }
        scheduled(before: id)
    }

    /// What sudo said when it refused, in the user's words. Pure, so it is unit tested.
    static func classifySudoFailure(_ output: String, exitCode: Int32) -> RebootError {
        let text = output.lowercased()
        // Classic sudo "Sorry, try again." / "1 incorrect password attempt"; sudo-rs (Ubuntu 26.04, seen on a real
        // server) "Authentication failed, try again." / "Authentication required but not attempted".
        if SudoElevation.isAuthFailure(output) { return .badPassword }
        if text.contains("must have a tty") || text.contains("requiretty") {
            return .sudoRefused("sudo on this server insists on a terminal (requiretty), so Rackoon can't hand it the password. Allow passwordless sudo for systemctl, or reboot from a terminal tab.")
        }
        if text.contains("not in the sudoers") || text.contains("not allowed to execute") || text.contains("not allowed to run sudo") {
            return .sudoRefused("This user is not allowed to use sudo on the server, so it can't reboot it. Use root, or give the user sudo rights.")
        }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("##") }
        return .failed(lines.isEmpty ? "The reboot command failed (exit \(exitCode))." : lines.joined(separator: " "))
    }

    private func readBootID() async throws -> String {
        let before = try await transport.run(Self.bootIDCommand, timeout: 10)
        let id = before.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard before.exitCode == 0, !id.isEmpty else {
            throw RebootError.failed("Could not read the server's boot id first: \(before.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return id
    }

    private func scheduled(before id: String) {
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
