import Foundation

/// Mirrors `DockerSnapshot` in spec/models.schema.json.
public struct DockerSnapshot: Sendable, Codable, Equatable {
    public var containers: [DockerContainer]
    public init(containers: [DockerContainer]) { self.containers = containers }

    /// Compose stacks grouped by project label, sorted by name. Containers without a project
    /// label are collected in one trailing "Standalone" group.
    public var stacks: [DockerStack] {
        var byProject: [String: [DockerContainer]] = [:]
        var standalone: [DockerContainer] = []
        for c in containers {
            if let p = c.project { byProject[p, default: []].append(c) } else { standalone.append(c) }
        }
        var result = byProject.keys.sorted().map { name -> DockerStack in
            let members = byProject[name]!.sorted { ($0.service ?? $0.name) < ($1.service ?? $1.name) }
            // Every container in a project carries the same compose labels. If they disagree (a container made by
            // an older file, a moved directory), there is no single file set to run against, so the stack gets none
            // and compose actions are refused instead of guessing.
            let layouts = Set(members.compactMap { c -> ComposeLayout? in
                guard let dir = c.workingDir else { return nil }
                return ComposeLayout(workingDir: dir, files: c.configFiles.isEmpty ? (c.configFile.map { [$0] } ?? []) : c.configFiles)
            })
            let layout = layouts.count == 1 ? layouts.first : nil
            return DockerStack(name: name, workingDir: layout?.workingDir,
                               configFile: layout?.files.first, configFiles: layout?.files ?? [],
                               containers: members, isStandalone: false)
        }
        if !standalone.isEmpty {
            result.append(DockerStack(name: "Standalone", workingDir: nil, configFile: nil, configFiles: [],
                                      containers: standalone.sorted { $0.name < $1.name }, isStandalone: true))
        }
        return result
    }
}

private struct ComposeLayout: Hashable {
    var workingDir: String
    var files: [String]
}

public struct DockerContainer: Sendable, Codable, Equatable, Identifiable {
    public struct PortMapping: Sendable, Codable, Equatable, Hashable {
        public var hostPort: Int
        public var containerPort: Int
        public var proto: String
    }

    /// Short container id (12 hex chars), as `docker ps` prints it.
    public var id: String
    public var name: String
    public var image: String
    /// running, exited, paused, restarting, created, removing, dead
    public var state: String
    /// none, starting, healthy, unhealthy
    public var health: String
    /// Docker's own status text, e.g. "Up 3 hours (healthy)".
    public var status: String
    /// Published ports only (host to container), de-duplicated across IPv4/IPv6 and bind addresses.
    public var ports: [PortMapping]
    public var project: String?
    public var service: String?
    public var workingDir: String?
    /// First compose file (for display).
    public var configFile: String?
    /// All compose files, in the order compose merges them (the label is a comma-separated list).
    public var configFiles: [String] = []
    public var cpuPercent: Double?
    public var memoryUsedBytes: Int64?
    public var memoryLimitBytes: Int64?
    /// From the container's `homepage.*` labels (the Homepage dashboard convention); nil when it has no valid `homepage.href`.
    public var bookmark: Bookmark?

    public var isRunning: Bool { state == "running" || state == "restarting" }
    public var isUnhealthy: Bool { health == "unhealthy" }
}

public struct DockerStack: Sendable, Equatable, Identifiable {
    public var name: String
    public var workingDir: String?
    public var configFile: String?
    public var configFiles: [String]
    public var containers: [DockerContainer]
    public var isStandalone: Bool
    public var id: String { name }

    public var configFileName: String? { configFile.map { ($0 as NSString).lastPathComponent } }
    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var unhealthyCount: Int { containers.filter(\.isUnhealthy).count }
    public var stoppedCount: Int { containers.count - runningCount }
    /// True when any container of the stack has a bookmark.
    public var hasBookmark: Bool { containers.contains { $0.bookmark != nil } }
}

public enum DockerParseError: Error, Equatable, LocalizedError {
    case notInstalled
    /// Docker is installed but the command failed (daemon down, permission denied...). Carries docker's message.
    case daemon(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Docker is not installed on this server."
        case .daemon(let m): m
        case .malformed(let d): "Unexpected docker output: \(d)"
        }
    }
}
