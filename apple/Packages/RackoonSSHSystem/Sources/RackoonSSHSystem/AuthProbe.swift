import Foundation
import RackoonCore
import Subprocess

/// After a server answers "Permission denied": one more login attempt, verbose this time (`ssh -v … true`), to learn
/// which keys ssh offered and what the server accepts, so the Overview can say what to do instead of showing the bare
/// refusal. Batch mode like every other connection: it never prompts, and it runs the harmless `true`.
public enum AuthProbe {
    public static func attempt(_ server: Server, knownHostsPath: String? = nil) async -> SSHAttempt {
        var args = ["-v", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none"]
        if let knownHostsPath { args += ["-o", "UserKnownHostsFile=\(knownHostsPath)"] }
        if let port = server.port { args += ["-p", String(port)] }
        args += OpenSSHTransport.identityArguments(server.identityFile)
        args += [server.sshDestination, "true"]
        do {
            let result = try await Subprocess.run(.path("/usr/bin/ssh"), arguments: Arguments(args), input: .none,
                                                  output: .discarded, error: .bytes(limit: 1 << 20))
            return SSHAttempt.parse(String(decoding: result.standardError, as: UTF8.self))
        } catch {
            return SSHAttempt()
        }
    }
}
