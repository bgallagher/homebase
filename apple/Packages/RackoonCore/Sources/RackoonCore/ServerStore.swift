import Foundation

/// Saved servers and each server's last good Overview, as JSON files under one directory.
/// Secrets never go here (Keychain only).
public struct ServerStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func defaultStore() -> ServerStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateLegacyDirectory(in: base)
        return ServerStore(directory: base.appendingPathComponent("Rackoon", isDirectory: true))
    }

    /// The app was called Homebase before it was Rackoon. Copy (never move or delete) the old data once,
    /// so the user can check it before removing the old folder themselves.
    @discardableResult
    static func migrateLegacyDirectory(in base: URL) -> Bool {
        let fm = FileManager.default
        let old = base.appendingPathComponent("Homebase", isDirectory: true)
        let new = base.appendingPathComponent("Rackoon", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        return (try? fm.copyItem(at: old, to: new)) != nil
    }

    private var serversFile: URL { directory.appendingPathComponent("servers.json") }
    private func snapshotFile(_ id: String) -> URL {
        directory.appendingPathComponent("snapshots", isDirectory: true).appendingPathComponent("\(id).json")
    }

    public func loadServers() -> [Server] {
        guard let data = try? Data(contentsOf: serversFile) else { return [] }
        return (try? JSONDecoder().decode([Server].self, from: data)) ?? []
    }

    public func saveServers(_ servers: [Server]) throws {
        try write(try encoder.encode(servers), to: serversFile)
    }

    public struct CachedSnapshot: Codable, Equatable, Sendable {
        public var overview: Overview
        public var savedAt: Date
    }

    public func loadSnapshot(serverID: String) -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFile(serverID)) else { return nil }
        return try? JSONDecoder.iso.decode(CachedSnapshot.self, from: data)
    }

    public func saveSnapshot(_ overview: Overview, serverID: String, at date: Date = Date()) throws {
        try write(try JSONEncoder.iso.encode(CachedSnapshot(overview: overview, savedAt: date)),
                  to: snapshotFile(serverID))
    }

    public func deleteSnapshot(serverID: String) {
        try? FileManager.default.removeItem(at: snapshotFile(serverID))
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
