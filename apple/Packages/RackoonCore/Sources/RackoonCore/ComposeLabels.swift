import Foundation

public enum ComposeLabelsError: Error, Equatable, LocalizedError {
    case serviceNotFound(String)
    case inlineServices
    /// `labels:` is written as `{...}` or `[...]`.
    case flowLabels(String)
    /// The service uses a YAML merge key, so its labels may come from an anchor elsewhere.
    case mergeKey(String)

    public var errorDescription: String? {
        switch self {
        case .serviceNotFound(let n): "This compose file has no service called \(n)."
        case .inlineServices: "This file writes services on one line, so labels can't be edited automatically. Edit the file by hand."
        case .flowLabels(let n): "The labels of \(n) are written inline ({...} or [...]), so they can't be edited automatically. Edit the file by hand."
        case .mergeKey(let n): "\(n) uses a YAML merge key (<<:), so its labels may come from somewhere else. Edit the file by hand."
        }
    }
}

/// Sets and removes labels on one service of a compose file's text, as line edits only: every other label, comment and line
/// stays exactly as it was. Handles both `- key=value` lists and `key: value` maps, and a service with no labels yet.
public enum ComposeLabels {
    public static func definesService(_ name: String, in text: String) -> Bool { ComposeInsert.services(in: text).contains(name) }

    public static func setting(_ changes: [(key: String, value: String?)], onService name: String, in text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let services = ComposeInsert.servicesBlock(lines) else { throw ComposeLabelsError.serviceNotFound(name) }
        if services.inline { throw ComposeLabelsError.inlineServices }
        guard let step = ComposeInsert.childIndent(lines, services), step > 0,
              let header = (services.start + 1..<services.end).first(where: { isServiceHeader(lines[$0], name, step) })
        else { throw ComposeLabelsError.serviceNotFound(name) }

        // The service's own lines: up to the next line at the service level or shallower.
        var end = services.end
        for i in header + 1..<services.end where isContent(lines[i]) && indent(lines[i]) <= step { end = i; break }
        guard let keyIndent = (header + 1..<end).first(where: { isContent(lines[$0]) }).map({ indent(lines[$0]) }) else {
            return insertNew(changes, into: &lines, after: header, keyIndent: step + 2, unit: 2)   // an empty service
        }
        if (header + 1..<end).contains(where: { indent(lines[$0]) == keyIndent && trimmed(lines[$0]).hasPrefix("<<:") }) {
            throw ComposeLabelsError.mergeKey(name)
        }
        let unit = max(1, keyIndent - step)
        guard let labelsLine = (header + 1..<end).first(where: { indent(lines[$0]) == keyIndent && isKey(lines[$0], "labels") }) else {
            return insertNew(changes, into: &lines, after: lastContentLine(lines, header + 1..<end) ?? header, keyIndent: keyIndent, unit: unit)
        }
        var rest = String(trimmed(lines[labelsLine]).dropFirst("labels:".count))
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { throw ComposeLabelsError.flowLabels(name) }

        // The labels block: lines deeper than the `labels:` key.
        var blockEnd = end
        for i in labelsLine + 1..<end where isContent(lines[i]) && indent(lines[i]) <= keyIndent { blockEnd = i; break }
        let items = (labelsLine + 1..<blockEnd).filter { isContent(lines[$0]) }
        let isList = items.first.map { trimmed(lines[$0]).hasPrefix("- ") || trimmed(lines[$0]) == "-" } ?? true
        let itemIndent = items.first.map { indent(lines[$0]) } ?? keyIndent + unit

        for change in changes {
            let existing = (labelsLine + 1..<blockEnd).first { i in
                isContent(lines[i]) && indent(lines[i]) == itemIndent && labelKey(of: lines[i], list: isList) == change.key
            }
            let newLine = change.value.map { item(change.key, $0, list: isList, indent: itemIndent) }
            switch (existing, newLine) {
            case (let i?, let line?): lines[i] = line
            case (let i?, nil): lines.remove(at: i); blockEnd -= 1
            case (nil, let line?):
                let at = lastContentLine(lines, labelsLine + 1..<blockEnd) ?? labelsLine
                lines.insert(line, at: at + 1); blockEnd += 1
            case (nil, nil): break
            }
        }
        // Nothing left under `labels:`: drop the empty key too.
        if !(labelsLine + 1..<blockEnd).contains(where: { isContent(lines[$0]) }) { lines.removeSubrange(labelsLine..<blockEnd) }
        return lines.joined(separator: "\n")
    }

    // MARK: pieces

    private static func insertNew(_ changes: [(key: String, value: String?)], into lines: inout [String], after: Int, keyIndent: Int, unit: Int) -> String {
        let additions = changes.compactMap { c in c.value.map { item(c.key, $0, list: true, indent: keyIndent + unit) } }
        guard !additions.isEmpty else { return lines.joined(separator: "\n") }
        lines.insert(contentsOf: [String(repeating: " ", count: keyIndent) + "labels:"] + additions, at: after + 1)
        return lines.joined(separator: "\n")
    }

    private static func item(_ key: String, _ value: String, list: Bool, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        // `$` starts a variable in compose files, so a literal one is written `$$`.
        let v = value.replacingOccurrences(of: "$", with: "$$")
        return list ? pad + "- " + scalar("\(key)=\(v)") : pad + key + ": " + scalar(v)
    }

    /// A YAML scalar: plain when that is safe, double-quoted otherwise.
    static func scalar(_ s: String) -> String {
        let special = "-?:,[]{}#&*!|>'\"%@`"
        let needsQuotes = s.isEmpty || s != s.trimmingCharacters(in: .whitespaces) || s.contains(": ") || s.contains(" #") || s.hasSuffix(":")
            || s.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) || (special.contains(s.first!) && !s.hasPrefix("homepage."))
            || ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(s.lowercased()) || Double(s) != nil
        return needsQuotes ? "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
    }

    private static func labelKey(of line: String, list: Bool) -> String? {
        var body = trimmed(line)
        if list {
            guard body.hasPrefix("-") else { return nil }
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            body = unquote(body)
            return body.firstIndex(of: "=").map { String(body[..<$0]) } ?? body
        }
        guard let colon = body.firstIndex(of: ":") else { return nil }
        return unquote(String(body[..<colon]).trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    private static func isServiceHeader(_ line: String, _ name: String, _ step: Int) -> Bool {
        guard indent(line) == step else { return false }
        var rest = String(trimmed(line).dropFirst(name.count))
        guard trimmed(line).hasPrefix(name), rest.hasPrefix(":") else { return false }
        rest.removeFirst()
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }
        return rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isKey(_ line: String, _ key: String) -> Bool { trimmed(line).hasPrefix(key + ":") }
    private static func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func isContent(_ line: String) -> Bool { let t = trimmed(line); return !t.isEmpty && !t.hasPrefix("#") }
    private static func lastContentLine(_ lines: [String], _ range: Range<Int>) -> Int? { range.reversed().first { isContent(lines[$0]) } }
}
