import Foundation

public struct CommandResult: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// How Core talks to a server. Implemented by OpenSSHTransport (Mac) and,
/// later, an embedded SSH library (iOS, App Store). Core never imports Process.
public protocol SSHTransport: Sendable {
    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult
    func stream(_ command: String) -> AsyncThrowingStream<String, Error>
    /// Runs `command` with `input` written to its standard input, then closed. This is how a secret reaches a remote
    /// program without ever being part of the command text (a sudo password for `sudo -S`): it is not in `ps` on the
    /// server, not in a confirm sheet and not in any log. Implementations must never record `input`.
    func run(_ command: String, input: String, timeout: TimeInterval) async throws -> CommandResult
    /// `stream`, with every string from `input` typed into the remote pty as it arrives. Used to answer a sudo prompt
    /// (sudo turns the terminal's echo off, so the password is not shown). Implementations must never record `input`.
    func stream(_ command: String, input: AsyncStream<String>) -> AsyncThrowingStream<String, Error>
}

public enum TransportError: Error, LocalizedError, Equatable {
    /// The transport cannot feed standard input (the demo and older fakes).
    case inputNotSupported

    public var errorDescription: String? {
        switch self {
        case .inputNotSupported: "This connection cannot send input to a command."
        }
    }
}

public extension SSHTransport {
    func run(_ command: String, input: String, timeout: TimeInterval) async throws -> CommandResult {
        throw TransportError.inputNotSupported
    }

    func stream(_ command: String, input: AsyncStream<String>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: TransportError.inputNotSupported) }
    }
}
