import Foundation
import HomebaseCore

/// Stage 1: wraps /usr/bin/ssh (ControlMaster, BatchMode) so ~/.ssh/config and ssh-agent just work.
public struct OpenSSHTransport: SSHTransport {
    public let host: String

    public init(host: String) {
        self.host = host
    }

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        fatalError("Not implemented until Stage 1")
    }

    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        fatalError("Not implemented until Stage 1")
    }
}
