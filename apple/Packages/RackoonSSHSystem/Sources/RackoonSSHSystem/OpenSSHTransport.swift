import Foundation
import RackoonCore
import Subprocess

public enum OpenSSHError: Error, LocalizedError {
    case timedOut(TimeInterval)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let s): "Timed out after \(Int(s))s"
        case .launchFailed(let m): "Could not launch ssh: \(m)"
        }
    }
}

/// Wraps /usr/bin/ssh so ~/.ssh/config, ssh-agent and existing keys just work.
/// Commands share one multiplexed connection (ControlMaster) so polling is cheap.
public struct OpenSSHTransport: SSHTransport {
    public let host: String
    private let port: Int?
    private let controlDir: String

    public init(server: Server) {
        self.init(destination: server.sshDestination, port: server.port)
    }

    public init(host: String) {
        self.init(destination: host, port: nil)
    }

    private init(destination: String, port: Int?) {
        self.host = destination
        self.port = port
        self.controlDir = Self.controlDirectory()
    }

    /// Shared by command polling and terminal tabs so a new tab reuses the open connection.
    /// Unix socket paths are limited to ~104 bytes, so keep this short.
    static func controlDirectory() -> String {
        let dir = "/tmp/rk-\(getuid())"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Options for non-interactive command execution.
    /// Arguments for an interactive shell (`ssh -t`), used by the terminal view.
    public static func terminalArguments(for server: Server) -> [String] {
        // Keepalives make a dead link end the session (ssh exits 255 after about 45 s of silence), which is
        // what lets a terminal tab notice the drop and reconnect itself; without them ssh waits for TCP.
        var args = ["-t",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPersist=120",
                    "-o", "ControlPath=\(controlDirectory())/%C"]
        if let port = server.port { args += ["-p", String(port)] }
        return args + [server.sshDestination]
    }

    func baseArguments() -> [String] {
        (port.map { ["-p", String($0)] } ?? []) + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            "-o", "ControlPath=\(controlDir)/%C",
            host,
        ]
    }

    /// Most output one command may produce (a safety net; the largest real answers are a few hundred KB).
    static let outputLimit = 64 * 1024 * 1024

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        let arguments = Arguments(baseArguments() + [command])
        do {
            return try await withThrowingTaskGroup(of: CommandResult?.self) { group in
                group.addTask {
                    let result = try await Subprocess.run(
                        .path("/usr/bin/ssh"), arguments: arguments, input: .none,
                        output: .bytes(limit: Self.outputLimit), error: .bytes(limit: Self.outputLimit))
                    return CommandResult(stdout: String(decoding: result.standardOutput, as: UTF8.self),
                                         stderr: String(decoding: result.standardError, as: UTF8.self),
                                         exitCode: Self.exitCode(result.terminationStatus))
                }
                // The timer: whichever finishes first wins; cancelling the loser stops ssh (Subprocess kills it).
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let first else { throw OpenSSHError.timedOut(timeout) }
                return first
            }
        } catch let error as SubprocessError {
            throw OpenSSHError.launchFailed("\(error)")
        }
    }

    /// An exit status as ssh (and the old `Process`) reported it: the code, or the signal number if it was killed by one.
    static func exitCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): code
        case .signaled(let signal): signal
        }
    }

    /// Streams combined output over a forced remote pseudo-terminal (`-tt`), so lines end in \r\n.
    ///
    /// Stopping the stream sends Ctrl-C through that terminal first, which makes the remote command exit
    /// and ssh finish on its own. Killing the local ssh alone is not enough: some servers (Tailscale SSH,
    /// as found in testing) leave the remote process running, so a quiet `docker logs -f` would stay
    /// behind forever. The kill is only a fallback if ssh has not exited about two seconds after the Ctrl-C
    /// (the teardown sequence below: swift-subprocess kills the process when its grace period ends).
    ///
    /// Streams deliberately do NOT use the shared ControlMaster connection: in testing, Ctrl-C written to
    /// a multiplexed client never reached the remote command, but on its own connection it does.
    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        let args = ["-tt"] + (port.map { ["-p", String($0)] } ?? []) + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            host,
            command,
        ]
        return AsyncThrowingStream { continuation in
            let input = StdinBox()
            var options = PlatformOptions()
            // On cancellation: signal 0 delivers nothing (a pure grace period of two seconds for ssh to end by itself after
            // the Ctrl-C below), then swift-subprocess sends the final kill.
            options.teardownSequence = [.send(signal: Signal(rawValue: 0), allowedDurationToNextStep: .seconds(2))]
            let task = Task {
                do {
                    // Chunks can end in the middle of a multi-byte character; the chunker holds that tail for the next chunk.
                    var chunker = Utf8Chunker()
                    _ = try await Subprocess.run(
                        .path("/usr/bin/ssh"), arguments: Arguments(args), platformOptions: options,
                        input: .inputWriter, output: .sequence, error: .combinedWithOutput
                    ) { execution in
                        input.set(execution.standardInputWriter)
                        defer { input.clear() }
                        for try await buffer in execution.standardOutput {
                            let text = chunker.push(Data(buffer.withUnsafeBytes { Array($0) }))
                            if !text.isEmpty { continuation.yield(text) }
                        }
                        let tail = chunker.finish()
                        if !tail.isEmpty { continuation.yield(tail) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: OpenSSHError.launchFailed("\(error)"))
                }
            }
            continuation.onTermination = { _ in
                // Ctrl-C to the remote pty first, then cancel: the task's teardown gives ssh its grace period.
                Task {
                    await input.sendInterrupt()
                    task.cancel()
                }
            }
        }
    }
}

/// The running ssh's stdin writer, reachable from outside the run body so a cancelled stream can type Ctrl-C into it.
private final class StdinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: StandardInputWriter?

    func set(_ w: StandardInputWriter) { lock.withLock { writer = w } }
    func clear() { lock.withLock { writer = nil } }

    /// Errors are ignored: the process may already be gone.
    func sendInterrupt() async {
        let w = lock.withLock { writer }
        _ = try? await w?.write([0x03])
    }
}
