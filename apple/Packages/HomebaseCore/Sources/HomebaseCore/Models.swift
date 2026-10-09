import Foundation

/// Mirrors `Server` in spec/models.schema.json.
public struct Server: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var host: String
    public var sshConfigAlias: String?

    public init(id: String, name: String, host: String, sshConfigAlias: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.sshConfigAlias = sshConfigAlias
    }
}
