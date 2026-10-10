import Foundation

public enum ImageStatus: Sendable, Equatable {
    case found
    /// The registry has no such image or tag, or it needs a login this server doesn't have.
    case notFound
    case timedOut
}

/// The read-only checks behind the Add container page, run on the server: does the image exist, which ports are
/// already listening. Templates equal the scripts in spec/commands.json (`image_exists`, `listening_ports`).
public enum ContainerChecks {
    public static let imageTemplate = #"timeout 20 docker manifest inspect {image} >/dev/null 2>&1; case $? in 0) echo found;; 124) echo timeout;; *) echo notfound;; esac"#
    public static let listeningPortsCommand = "ss -H -tln 2>/dev/null"

    public static func imageCommand(_ image: String) -> String? {
        let spec = ContainerSpec(name: "x", image: image)
        guard !image.isEmpty, spec.imageProblem == nil, let quoted = ShellQuote.quote(image) else { return nil }
        return Template.fill(imageTemplate, ["image": quoted])
    }

    public static func parseImageStatus(_ output: String) -> ImageStatus {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "found": .found
        case "timeout": .timedOut
        default: .notFound
        }
    }

    /// Ports in `ss -H -tln` output: the local address is the fourth column, and the port follows its last colon
    /// (`0.0.0.0:80`, `[::]:80`, `127.0.0.53%lo:53`).
    public static func parseListeningPorts(_ output: String) -> Set<Int> {
        var ports: Set<Int> = []
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 4, let colon = columns[3].lastIndex(of: ":"),
                  let port = Int(columns[3][columns[3].index(after: colon)...]) else { continue }
            ports.insert(port)
        }
        return ports
    }

    /// "Docker Hub" for images with no registry host in the name, otherwise the host (`ghcr.io`).
    public static func registryName(_ image: String) -> String {
        let parts = image.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1, let first = parts.first, first.contains(".") || first.contains(":") || first == "localhost" else { return "Docker Hub" }
        return String(first)
    }

    // MARK: checklist rows (the four from the design: YAML, image, ports, container name)

    public static func imageRow(_ spec: ContainerSpec, status: ImageStatus?) -> EditorCheckRow {
        typealias R = EditorCheckRow
        guard spec.imageProblem == nil, !spec.image.isEmpty else {
            return R(id: "image", state: .skipped, title: "Image", detail: spec.imageProblem ?? "Enter an image")
        }
        switch status {
        case nil: return R(id: "image", state: .running, title: "Image", detail: "Looking for \(spec.image)…")
        case .found?: return R(id: "image", state: .pass, title: "Image", detail: "\(spec.image) found on \(registryName(spec.image))")
        case .notFound?: return R(id: "image", state: .fail, title: "Image", detail: "\(spec.image) not found on \(registryName(spec.image)), or it needs a login")
        case .timedOut?: return R(id: "image", state: .warn, title: "Image", detail: "The registry didn't answer in time, so \(spec.image) is unchecked")
        }
    }

    /// One row per published host port. A port counts as taken if something listens on it on the server (which covers
    /// Docker's own published ports); the owner is named when a known container publishes it.
    public static func portRows(_ spec: ContainerSpec, listening: Set<Int>?, containers: [DockerContainer], serverName: String) -> [EditorCheckRow] {
        typealias R = EditorCheckRow
        let wanted = spec.activePorts.compactMap { row -> Int? in ContainerSpec.portProblem(row) == nil ? row.hostPort : nil }
        var rows: [R] = []
        var seen: Set<Int> = []
        for port in wanted where seen.insert(port).inserted {
            guard let listening else {
                rows.append(R(id: "port\(port)", state: .running, title: "Port \(port)", detail: "Checking \(serverName)…"))
                continue
            }
            if wanted.filter({ $0 == port }).count > 1 {
                rows.append(R(id: "port\(port)", state: .fail, title: "Port \(port) is used twice", detail: "Two mappings publish it"))
            } else if listening.contains(port) {
                let owner = containers.first { $0.ports.contains { $0.hostPort == port } }
                let by = owner.map { c in "By \(c.service ?? c.name)" + (c.project.map { " in \($0)" } ?? "") + "." } ?? "Something on \(serverName) is already listening on it."
                let free = (port + 1...min(port + 200, 65535)).first { !listening.contains($0) && !wanted.contains($0) }
                rows.append(R(id: "port\(port)", state: .fail, title: "Port \(port) is already in use", detail: by + (free.map { " Try \($0)." } ?? "")))
            } else {
                rows.append(R(id: "port\(port)", state: .pass, title: "Port \(port)", detail: "Free on \(serverName)"))
            }
        }
        return rows
    }

    /// The container's name must not clash with a container that exists: compose names it `<stack>-<service>-1`.
    public static func nameRow(_ spec: ContainerSpec, stack: String?, containers: [DockerContainer]) -> EditorCheckRow {
        typealias R = EditorCheckRow
        guard !spec.name.isEmpty, spec.nameProblem == nil else {
            return R(id: "name", state: .skipped, title: "Container name", detail: spec.nameProblem ?? "Enter a name")
        }
        var taken = [spec.name]
        if let stack, !stack.isEmpty { taken.append("\(stack)-\(spec.name)-1") }
        if let clash = containers.first(where: { taken.contains($0.name) }) {
            return R(id: "name", state: .fail, title: "Container name", detail: "A container named \(clash.name) already exists")
        }
        return R(id: "name", state: .pass, title: "Container name", detail: "\(spec.name) is free")
    }

    /// The compose result as one row in the common case: the design shows a single "YAML syntax" line when all is well,
    /// and the specific failing row (syntax, schema or config) otherwise.
    public static func composeRow(_ rows: [EditorCheckRow], serverName: String) -> [EditorCheckRow] {
        if rows.contains(where: { $0.state == .running }) {
            return [EditorCheckRow(id: "yaml", state: .running, title: "YAML syntax", detail: "Checking on \(serverName)…")]
        }
        if rows.allSatisfy({ $0.state == .pass || $0.state == .warn }) {
            return [EditorCheckRow(id: "yaml", state: .pass, title: "YAML syntax", detail: "Valid, and resolves cleanly on \(serverName)")]
                + rows.filter { $0.state == .warn }
        }
        return rows.filter { $0.state == .fail || $0.state == .warn }
    }
}

/// Runs the server-side lookups. Failures are not errors here: an unreachable server shows up as an unchecked row.
public struct ContainerChecker: Sendable {
    private let transport: SSHTransport
    public init(transport: SSHTransport) { self.transport = transport }

    public func imageStatus(_ image: String) async -> ImageStatus? {
        guard let command = ContainerChecks.imageCommand(image),
              let result = try? await transport.run(command, timeout: 30), result.exitCode == 0 else { return nil }
        return ContainerChecks.parseImageStatus(result.stdout)
    }

    public func listeningPorts() async -> Set<Int>? {
        guard let result = try? await transport.run(ContainerChecks.listeningPortsCommand, timeout: 10), result.exitCode == 0 else { return nil }
        return ContainerChecks.parseListeningPorts(result.stdout)
    }
}
