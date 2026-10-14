import Foundation

// The dashboard's view across every saved server: recent health history, fleet totals, Docker totals per server.
// Pure functions of readings the app already has (the Overview and Docker polls); nothing here runs a command.

/// One check of a server, as the dashboard's history keeps it.
public struct HealthSample: Sendable, Equatable {
    public var at: Date
    /// The poll answered.
    public var up: Bool
    public var cpuPercent: Double?
    public var memoryFraction: Double?
    /// The fullest disk's use, 0...1.
    public var diskFraction: Double?

    public init(at: Date, up: Bool, cpuPercent: Double? = nil, memoryFraction: Double? = nil, diskFraction: Double? = nil) {
        self.at = at
        self.up = up
        self.cpuPercent = cpuPercent
        self.memoryFraction = memoryFraction
        self.diskFraction = diskFraction
    }

    /// The sample a poll's result stands for, or nil for a reading that is not a check (a cached snapshot shown before
    /// the first poll, or nothing yet).
    public init?(state: ServerState, at: Date) {
        if let error = state.error, !error.isEmpty {
            self.init(at: at, up: false)
            return
        }
        guard let o = state.overview, !state.isStale else { return nil }
        self.init(at: at, up: true, cpuPercent: state.cpuPercent, memoryFraction: o.memory.usedFraction,
                  diskFraction: o.disks.map { Double($0.usePercent) / 100 }.max())
    }
}

/// A server's recent checks, about one a minute, for the last hour: the dashboard's heartbeat bar, uptime and sparklines.
/// Kept in memory only, so it starts empty each time the app opens.
public struct HealthHistory: Sendable, Equatable {
    /// The selected server is polled every few seconds; keeping one sample a minute makes every server's bar alike.
    public static let spacing: TimeInterval = 55
    public static let capacity = 60

    public private(set) var samples: [HealthSample] = []

    public init(samples: [HealthSample] = []) { self.samples = Array(samples.suffix(Self.capacity)) }

    /// Keeps `sample` unless the last one is under `spacing` old and says the same thing (up or down). A server going
    /// down or coming back is always kept, however soon, so a short outage is never hidden.
    public mutating func record(_ sample: HealthSample) {
        if let last = samples.last, last.up == sample.up, sample.at.timeIntervalSince(last.at) < Self.spacing { return }
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// The share of checks that answered, or nil with no checks yet.
    public var uptimeFraction: Double? {
        samples.isEmpty ? nil : Double(samples.filter(\.up).count) / Double(samples.count)
    }

    public var downCount: Int { samples.filter { !$0.up }.count }
}

/// Totals across the servers that have a reading.
public struct FleetTotals: Sendable, Equatable {
    public var servers = 0
    /// Answering now (the last poll succeeded).
    public var online = 0
    /// CPU use across the fleet, each server weighted by its cores; nil until some server has two readings.
    public var cpuPercent: Double?
    public var memoryUsed: Int64 = 0
    public var memoryTotal: Int64 = 0
    public var diskUsed: Int64 = 0
    public var diskTotal: Int64 = 0
    public var updates = 0
    public var securityUpdates = 0
    public var rebootRequired = 0
    public var unhealthyContainers = 0

    public init() {}

    /// `states` are every saved server's latest reading (cached or live). Online counts only fresh, error-free ones; the
    /// sums use the last known numbers of every server, so an offline server still counts its disks and updates.
    public static func of(_ states: [ServerState]) -> FleetTotals {
        var t = FleetTotals()
        var weighted = 0.0, cores = 0
        for s in states {
            t.servers += 1
            if s.error == nil, s.overview != nil, !s.isStale { t.online += 1 }
            guard let o = s.overview else { continue }
            if let cpu = s.cpuPercent {
                weighted += cpu * Double(max(o.cores, 1))
                cores += max(o.cores, 1)
            }
            t.memoryUsed += o.memory.usedBytes
            t.memoryTotal += o.memory.totalBytes
            for d in o.disks {
                t.diskUsed += d.usedBytes
                t.diskTotal += d.totalBytes
            }
            t.updates += o.pendingUpdates
            t.securityUpdates += o.securityUpdates
            if o.rebootRequired { t.rebootRequired += 1 }
            t.unhealthyContainers += o.unhealthyContainers.count
        }
        t.cpuPercent = cores > 0 ? weighted / Double(cores) : nil
        return t
    }
}

/// One server's Docker at a glance: how many containers run, and what they use of the host.
public struct DockerTotals: Sendable, Equatable {
    public var stacks = 0
    public var containers = 0
    public var running = 0
    public var unhealthy = 0
    /// The containers' CPU as a share of the whole host (docker counts 100% per core), nil without stats or core count.
    public var cpuPercentOfHost: Double?
    public var memoryBytes: Int64 = 0
    /// The containers' memory as a share of the host's, nil without the host's total.
    public var memoryFractionOfHost: Double?
    /// The disk that holds Docker's data (images, volumes, containers), when the server reports its mounts.
    public var dataDisk: Overview.Disk?

    public init() {}

    /// Where Docker keeps its data unless the daemon is configured otherwise.
    public static let dataRoot = "/var/lib/docker"

    public static func of(_ snapshot: DockerSnapshot, host overview: Overview?) -> DockerTotals {
        var t = DockerTotals()
        let stacks = snapshot.stacks
        t.stacks = stacks.filter { !$0.isStandalone }.count
        t.containers = snapshot.containers.count
        t.running = snapshot.containers.filter(\.isRunning).count
        t.unhealthy = snapshot.containers.filter(\.isUnhealthy).count
        let cpus = snapshot.containers.compactMap(\.cpuPercent)
        if !cpus.isEmpty, let cores = overview?.cores, cores > 0 { t.cpuPercentOfHost = cpus.reduce(0, +) / Double(cores) }
        t.memoryBytes = snapshot.containers.compactMap(\.memoryUsedBytes).reduce(0, +)
        if let total = overview?.memory.totalBytes, total > 0 { t.memoryFractionOfHost = Double(t.memoryBytes) / Double(total) }
        t.dataDisk = overview.flatMap { disk(holding: dataRoot, in: $0.disks) }
        return t
    }

    /// The mounted filesystem a path lives on: the mount point that is the longest prefix of it.
    public static func disk(holding path: String, in disks: [Overview.Disk]) -> Overview.Disk? {
        disks.filter { d in
            d.mount == "/" || path == d.mount || path.hasPrefix(d.mount.hasSuffix("/") ? d.mount : d.mount + "/")
        }
        .max { $0.mount.count < $1.mount.count }
    }
}

extension DockerStack {
    /// Container ports a web app usually listens on, best first.
    static let webPorts = [80, 443, 8080, 3000, 8000, 8443, 5000, 9000, 8081, 8888, 3001, 5173, 8096, 9443, 8123]

    /// The port the stack's web front end is published on, if it looks like it has one: the port in its bookmark's
    /// address, else a published TCP port whose container side is a usual web port, else nil.
    public var mainWebPort: Int? {
        let published = containers.flatMap(\.ports).filter { $0.proto == "tcp" }
        for href in containers.compactMap({ $0.bookmark?.href }) {
            if let port = URLComponents(string: href)?.port, published.contains(where: { $0.hostPort == port }) { return port }
        }
        for web in Self.webPorts {
            if let p = published.first(where: { $0.containerPort == web }) { return p.hostPort }
        }
        return nil
    }

    /// Every published port, host side, without repeats, in order.
    public var publishedPorts: [Int] {
        var seen = Set<Int>()
        return containers.flatMap(\.ports).map(\.hostPort).filter { seen.insert($0).inserted }
    }
}
