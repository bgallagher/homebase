import Foundation

/// One concrete `Host` entry from ~/.ssh/config (wildcard patterns are skipped).
public struct SSHConfigHost: Sendable, Equatable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?

    public func asServer() -> Server {
        // Keep the alias as `host` so ssh applies the rest of the entry (IdentityFile, ProxyJump...).
        Server(name: alias, host: alias, sshConfigAlias: alias)
    }
}

/// Pure parser for ssh_config text. Reads only what the add-server list needs;
/// ssh itself still resolves the full config at connect time.
public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [Int] = []   // indexes in `hosts` that the lines below apply to

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (key, value) = split(line)
            switch key.lowercased() {
            case "host":
                current = []
                for alias in value.split(separator: " ").map(String.init) {
                    guard !alias.contains("*"), !alias.contains("?"), !alias.hasPrefix("!") else { continue }
                    hosts.append(SSHConfigHost(alias: alias))
                    current.append(hosts.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                for i in current where hosts[i].hostName == nil { hosts[i].hostName = value }
            case "user":
                for i in current where hosts[i].user == nil { hosts[i].user = value }
            case "port":
                for i in current where hosts[i].port == nil { hosts[i].port = Int(value) }
            default:
                break
            }
        }
        return hosts
    }

    /// "Key value" or "Key=value".
    private static func split(_ line: String) -> (String, String) {
        guard let i = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return (line, "") }
        let key = String(line[..<i])
        var rest = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") { rest = String(rest.dropFirst().dropLast()) }
        return (key, rest)
    }
}
