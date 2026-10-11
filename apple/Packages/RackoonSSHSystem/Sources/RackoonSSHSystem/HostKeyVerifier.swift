import Foundation
import RackoonCore
import Subprocess

/// What the user is asked to confirm the first time we meet a host.
public struct HostKeyOffer: Sendable, Equatable {
    public var hostname: String
    public var port: Int
    /// e.g. "256 SHA256:abc… host (ED25519)" as printed by ssh-keygen -l.
    public var fingerprints: [String]
    /// Exactly what will be appended to known_hosts if the user trusts it, so the fingerprint
    /// shown is the key that gets stored.
    public var knownHostsLines: String
}

public enum HostKeyStatus: Sendable, Equatable {
    case trusted
    case unknown(HostKeyOffer)
    /// The stored key does not match. Never offered for acceptance.
    case changed(String)
    case failed(String)
}

/// Checks a server's host key with strict checking so ssh never silently accepts it,
/// and records a key only after the user has seen its fingerprint.
public struct HostKeyVerifier: Sendable {
    public let knownHostsPath: String

    public init(knownHostsPath: String = NSString(string: "~/.ssh/known_hosts").expandingTildeInPath) {
        self.knownHostsPath = knownHostsPath
    }

    enum Outcome: Equatable { case trusted, unknownKey, changedKey, other(String) }

    /// Maps the result of `ssh -o StrictHostKeyChecking=yes … true` to an outcome. Pure, so it is unit tested.
    static func classify(exitCode: Int32, stderr: String) -> Outcome {
        if exitCode == 0 { return .trusted }
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || stderr.contains("Offending") {
            return .changedKey
        }
        if stderr.contains("Host key verification failed") { return .unknownKey }
        // The key was accepted and authentication is what failed: the session will show that error.
        if stderr.contains("Permission denied") { return .trusted }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .other(detail.isEmpty ? "ssh exited with code \(exitCode)" : detail)
    }

    public func check(_ server: Server) async -> HostKeyStatus {
        var args = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none",
                    "-o", "UserKnownHostsFile=\(knownHostsPath)"]
        if let port = server.port { args += ["-p", String(port)] }
        args += [server.sshDestination, "true"]
        let result = await Self.run(.path("/usr/bin/ssh"), args)
        switch Self.classify(exitCode: result.code, stderr: result.stderr) {
        case .trusted: return .trusted
        case .changedKey:
            return .changed("The host key for \(server.host) has changed since you last connected. "
                + "This could be a reinstall or someone intercepting the connection. Remove the old entry from known_hosts only if you expected this.")
        case .other(let detail): return .failed(detail)
        case .unknownKey: return await offer(for: server)
        }
    }

    private func offer(for server: Server) async -> HostKeyStatus {
        // Resolve alias, HostName and port exactly as ssh will.
        var gArgs = ["-G"]
        if let port = server.port { gArgs += ["-p", String(port)] }
        gArgs.append(server.sshDestination)
        let config = await Self.run(.path("/usr/bin/ssh"), gArgs)
        var hostname = server.host, port = server.port ?? 22
        for line in config.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "hostname" { hostname = parts[1] }
            if parts[0] == "port", let p = Int(parts[1]) { port = p }
        }

        let scan = await Self.run(.path("/usr/bin/ssh-keyscan"), ["-T", "8", "-p", String(port), hostname])
        let lines = scan.stdout.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        guard !lines.isEmpty else {
            return .failed("Could not read the host key from \(hostname):\(port). \(scan.stderr)")
        }
        let keygen = await Self.run(.path("/usr/bin/ssh-keygen"), ["-l", "-f", "-"], stdin: lines + "\n")
        let prints = keygen.stdout.split(separator: "\n").map(String.init)
        guard keygen.code == 0, !prints.isEmpty else {
            return .failed("Could not compute the host key fingerprint.")
        }
        return .unknown(HostKeyOffer(hostname: hostname, port: port, fingerprints: prints, knownHostsLines: lines + "\n"))
    }

    /// Records the offered key. Call only after the user has confirmed the fingerprint.
    public func trust(_ offer: HostKeyOffer) throws {
        let url = URL(fileURLWithPath: knownHostsPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        try (existing + offer.knownHostsLines).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsPath)
    }

    private struct Result { var stdout: String; var stderr: String; var code: Int32 }

    private static func run(_ executable: Executable, _ args: [String], stdin: String? = nil) async -> Result {
        do {
            if let stdin {
                let result = try await Subprocess.run(executable, arguments: Arguments(args), input: .string(stdin),
                                                      output: .bytes(limit: 1 << 20), error: .bytes(limit: 1 << 20))
                return Result(stdout: String(decoding: result.standardOutput, as: UTF8.self),
                              stderr: String(decoding: result.standardError, as: UTF8.self),
                              code: OpenSSHTransport.exitCode(result.terminationStatus))
            }
            let result = try await Subprocess.run(executable, arguments: Arguments(args), input: .none,
                                                  output: .bytes(limit: 1 << 20), error: .bytes(limit: 1 << 20))
            return Result(stdout: String(decoding: result.standardOutput, as: UTF8.self),
                          stderr: String(decoding: result.standardError, as: UTF8.self),
                          code: OpenSSHTransport.exitCode(result.terminationStatus))
        } catch {
            return Result(stdout: "", stderr: "\(error)", code: -1)
        }
    }
}
