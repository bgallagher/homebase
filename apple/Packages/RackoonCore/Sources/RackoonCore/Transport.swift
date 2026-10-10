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
}
