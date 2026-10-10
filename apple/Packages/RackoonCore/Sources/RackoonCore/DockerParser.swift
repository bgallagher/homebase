import Foundation

/// Pure parser for the `docker` command output (sections `##docker`, `##ps`, `##stats`).
public enum DockerParser {
    public static func parse(_ output: String) throws -> DockerSnapshot {
        let sections = OverviewParser.splitSections(output)
        guard let status = sections["docker"]?.first else { throw DockerParseError.malformed("no ##docker section") }
        if status == "missing" { throw DockerParseError.notInstalled }

        let psLines = sections["ps"] ?? []
        if psLines.contains(where: { !$0.hasPrefix("{") }) {
            // Anything that is not a JSON row is docker's error text (daemon down, permission denied...).
            throw DockerParseError.daemon(psLines.joined(separator: "\n"))
        }

        var stats: [String: (cpu: Double?, used: Int64?, limit: Int64?)] = [:]
        for line in sections["stats"] ?? [] where line.hasPrefix("{") {
            guard let row = try? JSONDecoder().decode(StatsRow.self, from: Data(line.utf8)) else { continue }
            let mem = parseMemUsage(row.MemUsage)
            stats[row.ID] = (parsePercent(row.CPUPerc), mem?.used, mem?.limit)
        }

        var containers: [DockerContainer] = []
        for line in psLines {
            let row: PSRow
            do { row = try JSONDecoder().decode(PSRow.self, from: Data(line.utf8)) }
            catch { throw DockerParseError.malformed("ps row: \(error.localizedDescription)") }
            let labels = parseLabels(row.Labels ?? "")
            let s = stats[row.ID]
            let configFiles = (labels["com.docker.compose.project.config_files"] ?? "").split(separator: ",").map(String.init)
            containers.append(DockerContainer(
                id: row.ID, name: row.Names, image: row.Image,
                state: row.State, health: health(row.HealthStatus, status: row.Status), status: row.Status,
                ports: parsePorts(row.Ports ?? ""),
                project: labels["com.docker.compose.project"], service: labels["com.docker.compose.service"],
                workingDir: labels["com.docker.compose.project.working_dir"],
                configFile: configFiles.first, configFiles: configFiles,
                cpuPercent: s?.cpu, memoryUsedBytes: s?.used, memoryLimitBytes: s?.limit))
        }
        return DockerSnapshot(containers: containers)
    }

    private struct PSRow: Decodable {
        var ID: String
        var Names: String
        var Image: String
        var State: String
        var Status: String
        var HealthStatus: String?
        var Ports: String?
        var Labels: String?
    }

    private struct StatsRow: Decodable {
        var ID: String
        var CPUPerc: String
        var MemUsage: String
    }

    /// Newer Docker reports HealthStatus; older versions only put it in the status text.
    static func health(_ field: String?, status: String) -> String {
        if let field, !field.isEmpty { return field }
        if status.contains("(unhealthy)") { return "unhealthy" }
        if status.contains("(healthy)") { return "healthy" }
        if status.contains("(health: starting)") { return "starting" }
        return "none"
    }

    static func parseLabels(_ s: String) -> [String: String] {
        var map: [String: String] = [:]
        // Labels are comma-separated key=value pairs. A value may itself contain commas
        // (e.g. several compose files), so a piece without "=" continues the previous value.
        var last: String?
        for piece in s.split(separator: ",", omittingEmptySubsequences: true) {
            if let eq = piece.firstIndex(of: "=") {
                let k = String(piece[..<eq])
                map[k] = String(piece[piece.index(after: eq)...])
                last = k
            } else if let l = last {
                map[l, default: ""] += "," + piece
            }
        }
        return map
    }

    /// "127.0.0.1:8087->8080/tcp, [::]:8087->8080/tcp, 5432/tcp" -> published mappings only.
    static func parsePorts(_ s: String) -> [DockerContainer.PortMapping] {
        var seen = Set<DockerContainer.PortMapping>()
        var result: [DockerContainer.PortMapping] = []
        for part in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let arrow = part.range(of: "->") else { continue }
            let left = part[..<arrow.lowerBound], right = part[arrow.upperBound...]
            guard let hostPort = left.split(separator: ":").last.flatMap({ Int($0) }) else { continue } // skips ranges
            let rhs = right.split(separator: "/")
            guard rhs.count == 2, let containerPort = Int(rhs[0]) else { continue }
            let m = DockerContainer.PortMapping(hostPort: hostPort, containerPort: containerPort, proto: String(rhs[1]))
            if seen.insert(m).inserted { result.append(m) }
        }
        return result
    }

    static func parsePercent(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    /// "255.8MiB / 7.57GiB"
    static func parseMemUsage(_ s: String) -> (used: Int64, limit: Int64)? {
        let parts = s.components(separatedBy: " / ")
        guard parts.count == 2, let used = parseSize(parts[0]), let limit = parseSize(parts[1]) else { return nil }
        return (used, limit)
    }

    static func parseSize(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let i = t.firstIndex(where: { !($0.isNumber || $0 == ".") }) else { return nil }
        guard let n = Double(t[..<i]) else { return nil }
        let units: [String: Double] = [
            "B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
            "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776,
        ]
        guard let mult = units[String(t[i...])] else { return nil }
        return Int64((n * mult).rounded())
    }
}
