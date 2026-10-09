import Foundation

/// Mirrors `Overview` in spec/models.schema.json: one parsed reading of the `overview` command.
public struct Overview: Sendable, Codable, Equatable {
    public struct OS: Sendable, Codable, Equatable {
        public var id: String
        public var name: String
        public var version: String
        public var prettyName: String
    }

    public struct Memory: Sendable, Codable, Equatable {
        public var totalBytes: Int64
        public var availableBytes: Int64
        public var usedBytes: Int64 { totalBytes - availableBytes }
        public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    public struct Disk: Sendable, Codable, Equatable {
        public var filesystem: String
        public var mount: String
        public var totalBytes: Int64
        public var usedBytes: Int64
        /// Used share of the space a non-root user can use, as `df` reports it (0 to 100).
        public var usePercent: Int
    }

    /// Cumulative CPU counters from /proc/stat. Two readings give a utilisation percentage.
    public struct CPUCounters: Sendable, Codable, Equatable {
        public var total: Int64
        public var idle: Int64
    }

    public var hostname: String
    public var os: OS
    public var uptimeSeconds: Double
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var cores: Int
    public var cpu: CPUCounters
    public var memory: Memory
    public var disks: [Disk]
    public var rebootRequired: Bool
    /// Names of containers whose health check is failing (empty if docker is absent).
    public var unhealthyContainers: [String]

    /// CPU use (0 to 100) between an earlier reading and this one, or nil if no time passed.
    public func cpuPercent(since previous: Overview) -> Double? {
        let total = cpu.total - previous.cpu.total
        let idle = cpu.idle - previous.cpu.idle
        guard total > 0 else { return nil }
        return min(100, max(0, Double(total - idle) / Double(total) * 100))
    }
}
