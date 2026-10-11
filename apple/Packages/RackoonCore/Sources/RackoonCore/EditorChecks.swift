import Foundation

/// One line of the checklist under the editor.
public struct EditorCheckRow: Identifiable, Equatable, Sendable {
    public enum State: Sendable, Equatable { case pass, fail, warn, skipped, running }
    public let id: String
    public let state: State
    public let title: String
    public let detail: String

    public init(id: String, state: State, title: String, detail: String) {
        self.id = id
        self.state = state
        self.title = title
        self.detail = detail
    }
}

/// Turns what is known about a draft (local checks, the server's validation of the exact current text) into the
/// checklist from the design: YAML syntax, Compose schema, docker compose config (or .env syntax then the compose check).
public enum EditorChecks {
    public static func rows(isEnv: Bool, serverName: String, local: [ComposeIssue], checkError: String?,
                            validation: ValidationResult?, validatedText: String?, text: String) -> [EditorCheckRow] {
        typealias R = EditorCheckRow
        var rows: [R] = []

        if isEnv {
            if let first = local.first {
                return [R(id: "syntax", state: .fail, title: ".env syntax", detail: describe(first)),
                        R(id: "config", state: .skipped, title: "docker compose config", detail: "Skipped until the syntax is fixed")]
            }
            rows.append(R(id: "syntax", state: .pass, title: ".env syntax", detail: "Valid"))
        }
        if let failure = checkError {
            rows.append(R(id: "check", state: .fail, title: "Could not check on \(serverName)", detail: failure))
            return rows
        }
        // A result for older text must never read as the verdict on this text.
        guard let validation, validatedText == text else {
            rows.append(R(id: "running", state: .running, title: "Checking on \(serverName)…", detail: ""))
            return rows
        }

        let errors = validation.errors
        if isEnv {
            if let first = errors.first {
                rows.append(R(id: "config", state: .fail, title: "docker compose config", detail: describe(first)))
            } else {
                rows.append(R(id: "config", state: .pass, title: "docker compose config", detail: "Resolves cleanly on \(serverName)"))
            }
        } else {
            let syntax = errors.filter(isSyntax)
            let schema = errors.filter { !isSyntax($0) && isSchema($0) }
            let config = errors.filter { !isSyntax($0) && !isSchema($0) }
            if let first = syntax.first {
                rows.append(R(id: "syntax", state: .fail, title: "YAML syntax", detail: describe(first)))
                rows.append(R(id: "schema", state: .skipped, title: "Compose schema", detail: "Skipped until the syntax is fixed"))
                rows.append(R(id: "config", state: .skipped, title: "docker compose config", detail: "Skipped"))
            } else {
                rows.append(R(id: "syntax", state: .pass, title: "YAML syntax", detail: "Valid"))
                if let first = schema.first {
                    rows.append(R(id: "schema", state: .fail, title: "Compose schema", detail: describe(first)))
                    rows.append(R(id: "config", state: .skipped, title: "docker compose config", detail: "Skipped"))
                } else {
                    rows.append(R(id: "schema", state: .pass, title: "Compose schema", detail: "All keys recognised"))
                    if let first = config.first {
                        rows.append(R(id: "config", state: .fail, title: "docker compose config", detail: describe(first)))
                    } else {
                        rows.append(R(id: "config", state: .pass, title: "docker compose config", detail: "Resolves cleanly on \(serverName)"))
                    }
                }
            }
        }
        for (i, warning) in validation.warnings.enumerated() {
            rows.append(R(id: "warn\(i)", state: .warn, title: "Warning", detail: warning.message))
        }
        return rows
    }

    public static func describe(_ issue: ComposeIssue) -> String {
        issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message
    }

    private static func isSyntax(_ i: ComposeIssue) -> Bool {
        // Not just any mention of "yaml": a schema message names the file ("validating compose.yaml: ...").
        let m = i.message.lowercased()
        return i.line != nil || m.hasPrefix("yaml:") || m.contains("go-yaml") || m.contains("failed to parse")
    }

    private static func isSchema(_ i: ComposeIssue) -> Bool {
        let m = i.message.lowercased()
        return m.contains("validating") || m.contains("schema") || m.contains("additional property")
    }
}

extension ValidationResult {
    /// Names of the `${VARIABLES}` compose says are not set (`The "DB_PASSWORD" variable is not set. Defaulting to a blank
    /// string.`), in the order reported, each once. A file that needs them fails (or misbehaves) until they have values.
    public var unsetVariables: [String] {
        var seen = Set<String>(), out: [String] = []
        for issue in issues {
            guard let open = issue.message.range(of: "The \""), let close = issue.message.range(of: "\" variable is not set") else { continue }
            guard open.upperBound <= close.lowerBound else { continue }
            let name = String(issue.message[open.upperBound..<close.lowerBound])
            if name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, seen.insert(name).inserted { out.append(name) }
        }
        return out
    }
}
