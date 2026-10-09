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

    public init(id: String = UUID().uuidString, name: String, host: String,
                user: String? = nil, port: Int? = nil, sshConfigAlias: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.sshConfigAlias = sshConfigAlias
    }

    /// The `[user@]host` argument for ssh.
    public var sshDestination: String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }
}
