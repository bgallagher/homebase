import Foundation

public enum SudoTransportError: Error, Equatable, LocalizedError {
    /// The unlock window is over: nothing was sent.
    case locked
    /// sudo did not accept the password: nothing ran.
    case rejected
    /// The command can't be passed to `sh -c` as one word (it holds a newline or NUL).
    case cannotElevate

    public var errorDescription: String? {
        switch self {
        case .locked: "Docker access through sudo is locked again. Unlock it to continue."
        case .rejected: "The server did not accept the sudo password, so Docker access was locked."
        case .cannotElevate: "This command can't be run through sudo."
        }
    }
}

/// Runs every command of another transport as root through sudo, with a password the user gave for a limited time.
/// Used for Docker on servers where the ssh user may not use Docker directly: nothing on the server changes (no group
/// membership, no sudoers rule); each command simply runs as `sudo … sh -c '<command>'`.
///
/// Why the password is held here instead of asked per command: every command is its own ssh session, and sudo's own
/// grace period (its timestamp record) does not carry from one session to the next, so polling Docker every few seconds
/// would otherwise mean a prompt every few seconds. The app limits how long it is held (`validUntil`).
///
/// - `run`: `sudo -S -p '' sh -c '<command>'`, the password on stdin (never in the command), on the base transport's
///   `run(_:input:timeout:)`, which uses its own connection with a pinned host key.
/// - `stream`: the `SudoElevation` prefix (one `sudo -v`, nonce prompt answered once by `SudoHandshake`), then
///   `sudo -n sh -c '<command>'` in the same pty; the handshake's lines are not shown.
/// A rejected password calls `onRejected` (the app locks) and fails the command.
public final class SudoTransport: SSHTransport, @unchecked Sendable {
    private let base: SSHTransport
    private let password: String
    public let validUntil: Date
    private let onRejected: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private let makeNonce: @Sendable () -> String

    public init(base: SSHTransport, password: String, validUntil: Date, now: @escaping @Sendable () -> Date = { Date() },
                makeNonce: @escaping @Sendable () -> String = { SudoElevation.makeNonce() },
                onRejected: @escaping @Sendable () -> Void = {}) {
        self.base = base
        self.password = password
        self.validUntil = validUntil
        self.now = now
        self.makeNonce = makeNonce
        self.onRejected = onRejected
    }

    /// The root shell a command runs in, or nil if it can't be one `sh -c` word.
    public static func elevated(_ command: String) -> String? {
        ShellQuote.quote(command).map { "sudo -S -p '' sh -c " + $0 }
    }

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        guard now() < validUntil else { throw SudoTransportError.locked }
        guard let wrapped = Self.elevated(command) else { throw SudoTransportError.cannotElevate }
        let result = try await base.run(wrapped, input: password + "\n", timeout: timeout)
        if result.exitCode != 0, SudoElevation.isSudoAuthFailure(result.stderr) {
            onRejected()
            throw SudoTransportError.rejected
        }
        return result
    }

    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        guard now() < validUntil else { return AsyncThrowingStream { $0.finish(throwing: SudoTransportError.locked) } }
        guard let quoted = ShellQuote.quote(command) else {
            return AsyncThrowingStream { $0.finish(throwing: SudoTransportError.cannotElevate) }
        }
        let nonce = makeNonce()
        let full = Template.fill(SudoElevation.prefix, ["nonce": nonce]) + "sudo -n sh -c " + quoted
        let (typed, keyboard) = AsyncStream<String>.makeStream()
        let raw = base.stream(full, input: typed)
        let password = password
        let onRejected = onRejected
        return AsyncThrowingStream { continuation in
            let task = Task {
                var handshake = SudoHandshake(nonce: nonce)
                func show(_ text: String) {
                    let visible = text.replacingOccurrences(of: SudoHandshake.notice, with: "")
                    if !visible.isEmpty { continuation.yield(visible) }
                }
                do {
                    for try await chunk in raw {
                        let step = handshake.push(chunk)
                        for action in step.actions {
                            switch action {
                            case .typePassword: keyboard.yield(password + "\n")
                            case .interrupt: keyboard.yield("\u{03}")
                            }
                        }
                        show(step.shown)
                    }
                    show(handshake.finish())
                    keyboard.finish()
                    if handshake.outcome == .rejected {
                        onRejected()
                        continuation.finish(throwing: SudoTransportError.rejected)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    keyboard.finish()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
