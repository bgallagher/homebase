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
            return DockerStack(name: name, workingDir: members.compactMap(\.workingDir).first,
                               configFile: members.compactMap(\.configFile).first, containers: members, isStandalone: false)
        }
        if !standalone.isEmpty {
            result.append(DockerStack(name: "Standalone", workingDir: nil, configFile: nil,
                                      containers: standalone.sorted { $0.name < $1.name }, isStandalone: true))
        }
        return result
    }
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
    public var configFile: String?
    public var cpuPercent: Double?
    public var memoryUsedBytes: Int64?
    public var memoryLimitBytes: Int64?

    public var isRunning: Bool { state == "running" || state == "restarting" }
    public var isUnhealthy: Bool { health == "unhealthy" }
}

public struct DockerStack: Sendable, Equatable, Identifiable {
    public var name: String
    public var workingDir: String?
    public var configFile: String?
    public var containers: [DockerContainer]
    public var isStandalone: Bool
    public var id: String { name }

    public var configFileName: String? { configFile.map { ($0 as NSString).lastPathComponent } }
    public var runningCount: Int { containers.filter(\.isRunning).count }
    public var unhealthyCount: Int { containers.filter(\.isUnhealthy).count }
    public var stoppedCount: Int { containers.count - runningCount }
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
