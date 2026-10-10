import Foundation

public enum ParseError: Error, Equatable {
    case missingSection(String)
    case malformed(section: String, detail: String)
}

/// Pure parser for the `overview` command output. No I/O, so it ports 1:1 to Kotlin.
public enum OverviewParser {
    public static func parse(_ output: String) throws -> Overview {
        let sections = splitSections(output)
        func section(_ name: String) throws -> [String] {
            guard let lines = sections[name] else { throw ParseError.missingSection(name) }
            return lines
        }
        func bad(_ s: String, _ d: String) -> ParseError { .malformed(section: s, detail: d) }

        let hostname = try section("hostname").first ?? ""

        let osMap = keyValues(try section("os"))
        guard let osID = osMap["ID"] else { throw bad("os", "no ID") }
        let os = Overview.OS(
            id: osID,
            name: osMap["NAME"] ?? osID,
            version: osMap["VERSION_ID"] ?? "",
            prettyName: osMap["PRETTY_NAME"] ?? osMap["NAME"] ?? osID)

        guard let uptime = try section("uptime").first?.split(separator: " ").first.flatMap({ Double($0) })
        else { throw bad("uptime", "no seconds") }

        let load = try section("loadavg").first?.split(separator: " ").prefix(3).compactMap { Double($0) } ?? []
        guard load.count == 3 else { throw bad("loadavg", "need 3 numbers") }

        guard let cores = try section("nproc").first.flatMap({ Int($0) }) else { throw bad("nproc", "no number") }

        // cpu  user nice system idle iowait irq softirq steal ...
        let stat = try section("stat").first?.split(separator: " ").dropFirst().compactMap { Int64($0) } ?? []
        guard stat.count >= 8 else { throw bad("stat", "need at least 8 counters") }
        let cpu = Overview.CPUCounters(total: stat.prefix(8).reduce(0, +), idle: stat[3] + stat[4])

        let mem = keyValues(try section("meminfo"), separator: ":")
        func kb(_ key: String) throws -> Int64 {
            guard let v = mem[key]?.split(separator: " ").first.flatMap({ Int64($0) }) else {
                throw bad("meminfo", "no \(key)")
            }
            return v * 1024
        }
        let memory = Overview.Memory(totalBytes: try kb("MemTotal"), availableBytes: try kb("MemAvailable"))

        var disks: [Overview.Disk] = []
        for line in try section("df").dropFirst() {
            // Filesystem 1-blocks Used Available Capacity Mounted-on (mount may contain spaces)
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let total = Int64(f[1]), let used = Int64(f[2]),
                  let pct = Int(f[4].dropLast()) else { continue }
            disks.append(.init(filesystem: String(f[0]), mount: String(f[5]), totalBytes: total, usedBytes: used, usePercent: pct))
        }

        // Optional like `unhealthy`: output captured before this section existed still parses.
        let system = keyValues(sections["system"] ?? [])
        let timeParts = (system["time"] ?? "").split(separator: " ").map(String.init)
        let utcOffset: Int = {
            guard timeParts.count >= 2, timeParts[1].count == 5, let sign = timeParts[1].first, "+-".contains(sign),
                  let h = Int(timeParts[1].dropFirst().prefix(2)), let m = Int(timeParts[1].suffix(2)) else { return 0 }
            return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
        }()

        let reboot = try section("reboot").first == "yes"
        // Optional: older output and hosts without docker have no names here.
        let unhealthy = sections["unhealthy"] ?? []
        let pending = sections["updates"]?.first.flatMap { Int($0) } ?? 0
        let security = sections["security"]?.first.flatMap { Int($0) } ?? 0

        return Overview(
            vendor: system["vendor"] ?? "", product: system["product"] ?? "", machineID: system["machine_id"] ?? "",
            kernel: system["kernel"] ?? "", bootID: system["boot_id"] ?? "",
            serverTime: timeParts.first.flatMap { Int64($0) } ?? 0, utcOffsetSeconds: utcOffset,
            timeZoneName: timeParts.count >= 3 ? timeParts[2] : "",
            hostname: hostname, os: os, uptimeSeconds: uptime,
            load1: load[0], load5: load[1], load15: load[2], cores: cores,
            cpu: cpu, memory: memory, disks: disks, rebootRequired: reboot, unhealthyContainers: unhealthy,
            pendingUpdates: pending, securityUpdates: security)
    }

    static func splitSections(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("##") {
                current = String(line.dropFirst(2))
                result[current!] = []
            } else if let c = current, !line.isEmpty {
                result[c, default: []].append(line)
            }
        }
        return result
    }

    static func keyValues(_ lines: [String], separator: Character = "=") -> [String: String] {
        var map: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: separator) else { continue }
            let key = String(line[..<i])
            var value = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            map[key] = value
        }
        return map
    }
}
