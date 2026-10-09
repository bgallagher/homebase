import Foundation
import HomebaseCore

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
        let dir = "/tmp/hb-\(getuid())"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Options for non-interactive command execution.
    /// Arguments for an interactive shell (`ssh -t`), used by the terminal view.
    public static func terminalArguments(for server: Server) -> [String] {
        var args = ["-t",
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

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = baseArguments() + [command]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Drain pipes concurrently so a large output cannot fill the buffer and deadlock.
        let outTask = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }

        do { try process.run() } catch {
            throw OpenSSHError.launchFailed(error.localizedDescription)
        }

        let timedOut = TimeoutFlag()
        let killer = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            timedOut.set()
            process.terminate()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
            if !process.isRunning { process.terminationHandler = nil; c.resume() }
        }
        killer.cancel()

        let stdout = String(decoding: await outTask.value, as: UTF8.self)
        let stderr = String(decoding: await errTask.value, as: UTF8.self)
        if timedOut.value { throw OpenSSHError.timedOut(timeout) }
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Streams combined output over a forced remote pseudo-terminal (`-tt`), so lines end in \r\n.
    ///
    /// Stopping the stream sends Ctrl-C through that terminal first, which makes the remote command exit
    /// and ssh finish on its own. Killing the local ssh alone is not enough: some servers (Tailscale SSH,
    /// as found in testing) leave the remote process running, so a quiet `docker logs -f` would stay
    /// behind forever. The kill is only a fallback if ssh has not exited a couple of seconds after the Ctrl-C.
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
            let out = Pipe(), input = Pipe()
            process.standardOutput = out
            process.standardError = out
            process.standardInput = input
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                continuation.yield(String(decoding: data, as: UTF8.self))
            }
            process.terminationHandler = { _ in
                out.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
            }
            continuation.onTermination = { _ in
                guard process.isRunning else { return }
                try? input.fileHandleForWriting.write(contentsOf: Data([0x03])) // Ctrl-C to the remote pty
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { process.terminate() }
                }
            }
            do { try process.run() } catch {
                continuation.finish(throwing: OpenSSHError.launchFailed(error.localizedDescription))
            }
        }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
