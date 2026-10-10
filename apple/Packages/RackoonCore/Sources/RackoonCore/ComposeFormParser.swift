import Foundation

/// Reads a compose file back into the Add container form: the inverse of `ContainerSpec.yamlLines`, for the
/// common single-service file. It is deliberately small (line based, no YAML library), and says whether the file
/// uses anything the form cannot show (`lossless == false`: comments, other keys, literal environment values...),
/// in which case the file stays the source of truth and the form is only a read-out.
public enum ComposeFormParser {
    public struct Parsed: Equatable, Sendable {
        public var spec: ContainerSpec
        public var lossless: Bool
    }

    /// Nil when the text has no service, more than one, or no `services:` block. `env` supplies the values of
    /// `${NAME}` references so the environment rows show them.
    public static func parse(_ text: String, env: String = "") -> Parsed? {
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var lossless = true
        var inServices = false
        var serviceIndent: Int?
        var keyIndent: Int?
        var name: String?
        var spec = ContainerSpec(ports: [], volumes: [], env: [], restart: .no)
        var block = ""            // the key whose indented lines we are reading
        let values = envValues(env)

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { lossless = false; continue }
            let indent = raw.prefix { $0 == " " }.count
            if indent == 0 {
                inServices = trimmed == "services:"
                if !inServices { lossless = false }
                block = ""
                continue
            }
            guard inServices else { continue }
            if serviceIndent == nil { serviceIndent = indent }
            if indent == serviceIndent {
                guard trimmed.hasSuffix(":"), name == nil else { return nil }   // a second service, or something odd
                name = String(trimmed.dropLast())
                block = ""
                continue
            }
            guard name != nil else { return nil }
            if keyIndent == nil { keyIndent = indent }
            if indent == keyIndent {
                let (key, value) = split(trimmed)
                block = key
                switch key {
                case "image": spec.image = unquote(value)
                case "restart":
                    if let policy = RestartPolicy(rawValue: unquote(value)) { spec.restart = policy } else { lossless = false }
                case "ports", "volumes", "environment": if !value.isEmpty { lossless = false }
                default: lossless = false
                }
                continue
            }
            // A line inside a key's block.
            switch block {
            case "ports", "volumes":
                guard trimmed.hasPrefix("- ") else { lossless = false; continue }
                let item = unquote(String(trimmed.dropFirst(2)))
                let parts = item.components(separatedBy: ":")
                if block == "ports" {
                    guard parts.count == 2 || parts.count == 3 else { lossless = false; continue }
                    let container = parts.last!
                    if container.contains("/") { lossless = false }
                    spec.ports.append(PortRow(host: parts.dropLast().joined(separator: ":"), container: container))
                } else {
                    guard parts.count == 2 else { lossless = false; spec.volumes.append(VolumeRow(source: item, target: "")); continue }
                    spec.volumes.append(VolumeRow(source: parts[0], target: parts[1]))
                }
            case "environment":
                if trimmed.hasPrefix("- ") {
                    lossless = false
                    let item = unquote(String(trimmed.dropFirst(2)))
                    if let eq = item.firstIndex(of: "=") { spec.env.append(EnvRow(key: String(item[..<eq]), value: String(item[item.index(after: eq)...]))) }
                } else {
                    let (key, value) = split(trimmed)
                    let v = unquote(value)
                    if v == "${\(key)}" { spec.env.append(EnvRow(key: key, value: values[key] ?? "")) }
                    else { lossless = false; spec.env.append(EnvRow(key: key, value: v)) }
                }
            default:
                break   // inside a block we don't read; already marked lossy
            }
        }
        guard let name else { return nil }
        spec.name = name
        // The form always shows a blank row to type into.
        if spec.ports.isEmpty { spec.ports = [PortRow()] }
        if spec.volumes.isEmpty { spec.volumes = [VolumeRow()] }
        if spec.env.isEmpty { spec.env = [EnvRow()] }
        return Parsed(spec: spec, lossless: lossless)
    }

    private static func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" else { return t }
        return String(t.dropFirst().dropLast())
    }

    private static func envValues(_ env: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in env.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = unquote(String(line[line.index(after: eq)...]))
        }
        return out
    }
}
