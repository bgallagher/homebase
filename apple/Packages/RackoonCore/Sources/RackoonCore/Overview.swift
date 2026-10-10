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

    /// Hardware and system identity (from /sys/class/dmi, /etc/machine-id, uname). Empty when the server does not say.
    public var vendor: String
    public var product: String
    public var machineID: String
    public var kernel: String
    /// Changes on every boot; how a reboot is recognised.
    public var bootID: String
    /// The server's own IPv4 address (the source address of its route to the internet), and its Tailscale IPv4 address.
    /// Nil when unknown, and nil for Tailscale when it is not installed or not connected, so nothing is shown for it.
    /// Optional so snapshots cached by an earlier version still decode.
    public var ipAddress: String?
    public var tailscaleIP: String?
    /// The server's clock at the poll (Unix seconds), its UTC offset in seconds and its zone abbreviation.
    public var serverTime: Int64
    public var utcOffsetSeconds: Int
    public var timeZoneName: String

    /// "Hetzner vServer", or whatever part is known.
    public var modelName: String { [vendor, product].filter { !$0.isEmpty }.joined(separator: " ") }

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
    /// Packages apt can upgrade (from apt's local cache; 0 if apt is absent).
    public var pendingUpdates: Int
    /// Packages apt can upgrade from a security suite (0 if apt is absent).
    public var securityUpdates: Int

    /// CPU use (0 to 100) between an earlier reading and this one, or nil if no time passed.
    public func cpuPercent(since previous: Overview) -> Double? {
        let total = cpu.total - previous.cpu.total
        let idle = cpu.idle - previous.cpu.idle
        guard total > 0 else { return nil }
        return min(100, max(0, Double(total - idle) / Double(total) * 100))
    }
}
