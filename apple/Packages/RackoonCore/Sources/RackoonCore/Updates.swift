import Foundation

/// Mirrors `UpdatesSnapshot` in spec/models.schema.json: one parsed reading of the `updates` command.
public struct PendingUpdate: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    /// apt's suite list, e.g. "noble-updates,noble-security".
    public var suite: String
    public var newVersion: String
    public var oldVersion: String?
    public var architecture: String
    public var isSecurity: Bool

    public var id: String { name + ":" + architecture }
}

public struct UpdatesSnapshot: Sendable, Codable, Equatable {
    public var packages: [PendingUpdate]
    /// Packages pinned with `apt-mark hold`; apt will not upgrade them.
    public var held: [String]
    /// Unix time the package lists were last refreshed, when the server says.
    public var refreshedAt: Int64?
    public var rebootRequired: Bool

    public var securityCount: Int { packages.filter(\.isSecurity).count }
}

public enum UpdatesParseError: Error, Equatable {
    case notInstalled
    case malformed(String)
}
