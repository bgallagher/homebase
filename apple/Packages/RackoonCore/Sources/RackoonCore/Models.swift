import Foundation

/// Mirrors `Server` in spec/models.schema.json.
/// `host` is whatever ssh should connect to: a hostname, an IP, or a ~/.ssh/config alias.
public struct Server: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var host: String
    public var user: String?
    public var port: Int?
    /// Set when the server was imported from ~/.ssh/config (the alias is `host`).
    public var sshConfigAlias: String?
    /// A private key file to log in with (on the Mac: passed to ssh as `-i`, with IdentitiesOnly so that key alone is
    /// offered). Nil leaves the choice to ssh: its default key names, ssh-agent and ~/.ssh/config. May start with `~`.
    /// Unused on Android, which keeps keys in its own encrypted store.
    public var identityFile: String?

    public init(id: String = UUID().uuidString, name: String, host: String,
                user: String? = nil, port: Int? = nil, sshConfigAlias: String? = nil, identityFile: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.sshConfigAlias = sshConfigAlias
        self.identityFile = identityFile
    }

    /// True when both describe the same connection: everything but the id and the display name. A saved edit that only
    /// renames a server must not reconnect it.
    public func connectsLike(_ other: Server) -> Bool {
        host == other.host && user == other.user && port == other.port
            && sshConfigAlias == other.sshConfigAlias && identityFile == other.identityFile
    }

    /// The `[user@]host` argument for ssh.
    public var sshDestination: String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }
}
