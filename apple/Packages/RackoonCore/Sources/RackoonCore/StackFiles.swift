import Foundation

/// A file the stack editor can open: one of the stack's compose files, or the `.env` beside them.
public enum EditableFile: Sendable, Equatable, Hashable {
    /// Absolute path of one of the compose files named by the project's `config_files` label.
    case compose(String)
    /// Absolute path of `<working_dir>/.env`.
    case env(String)

    public var path: String {
        switch self { case .compose(let p), .env(let p): p }
    }
    public var isEnv: Bool { if case .env = self { true } else { false } }
    public var fileName: String { (path as NSString).lastPathComponent }
}

public enum StackFiles {
    /// Largest file the editor will open or save. The content travels inside one remote command line, and Linux
    /// caps a single argument at 128 KiB (base64 adds a third), so stay well under.
    public static let maxBytes = 65_536

    /// The files offered for a stack: every compose file in merge order, then `.env`. Nil if the stack has no
    /// single usable compose layout (the same rule the compose actions use).
    public static func editable(for stack: DockerStack) -> [EditableFile]? {
        guard let dir = stack.workingDir, ComposeAction.up.command(for: stack) != nil else { return nil }
        let paths = stack.configFiles.isEmpty ? (stack.configFile.map { [$0] } ?? []) : stack.configFiles
        return paths.map(EditableFile.compose) + [.env(envPath(directory: dir))]
    }

    static func envPath(directory: String) -> String {
        directory.hasSuffix("/") ? directory + ".env" : directory + "/.env"
    }
}

/// What reading a file on the server found.
public enum RemoteFileState: Sendable, Equatable {
    case missing
    case tooLarge
    case file(RemoteFile)

    public var content: String? { if case .file(let f) = self { f.content } else { nil } }
    /// The hash to send back when saving, so a change made on the server in between is noticed. Nil for no file.
    public var sha256: String? { if case .file(let f) = self { f.sha256 } else { nil } }
}

public struct RemoteFile: Sendable, Equatable, Codable {
    public var content: String
    public var sha256: String
    /// Octal permissions as `stat` prints them, e.g. "644".
    public var mode: String
    /// "owner:group".
    public var owner: String
    public var modifiedAt: Int64

    public init(content: String, sha256: String, mode: String, owner: String, modifiedAt: Int64) {
        self.content = content
        self.sha256 = sha256
        self.mode = mode
        self.owner = owner
        self.modifiedAt = modifiedAt
    }
}

public enum StackFileError: Error, Equatable, LocalizedError {
    case noEditableFiles
    case notEditable(String)
    case tooLarge
    case notText
    case cannotWrite
    case malformed(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noEditableFiles: "This stack has no single compose file to edit."
        case .notEditable(let p): "\(p) is not one of this stack's files."
        case .tooLarge: "The file is larger than \(StackFiles.maxBytes / 1024) KB, so it can't be edited here."
        case .notText: "The file is not valid UTF-8 text."
        case .cannotWrite: "Rackoon can't write in the stack's folder on the server (permissions)."
        case .malformed(let m): "Unexpected output reading the file: \(m)"
        case .commandFailed(let m): m
        }
    }
}

public struct ComposeIssue: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Codable { case error, warning }
    public init(severity: Severity, line: Int?, message: String) {
        self.severity = severity
        self.line = line
        self.message = message
    }
    public var severity: Severity
    /// 1-based line in the edited file when compose reported one.
    public var line: Int?
    public var message: String
}

public struct ValidationResult: Sendable, Equatable {
    public var issues: [ComposeIssue]
    public init(issues: [ComposeIssue]) { self.issues = issues }
    public var errors: [ComposeIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ComposeIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }
}

public enum SaveOutcome: Sendable, Equatable {
    /// Written. Carries the new hash for the next save.
    case saved(sha256: String)
    /// The file on the server is no longer the one that was opened.
    case changedOnServer
    /// The server's own `docker compose config` rejected it; nothing was written.
    case invalid([ComposeIssue])
}

extension ComposeIssue {
    /// The server checks a temp copy (`.rackoon-check.XXXXXX` / `.rackoon-save.XXXXXX`) of the edited file, and
    /// compose names it in its messages. Show the file the user is editing instead.
    func naming(_ file: EditableFile) -> ComposeIssue {
        var copy = self
        copy.message = message.replacingOccurrences(of: #"[^\s:"']*\.rackoon-(check|save)\.[A-Za-z0-9]+"#, with: file.fileName,
                                                    options: .regularExpression)
        return copy
    }
}

/// Parses the `file_read` output (`##missing`, `##toolarge`, or `##meta`/`##sha256`/`##content`).
public enum RemoteFileParser {
    public static func parse(_ output: String) throws -> RemoteFileState {
        let sections = OverviewParser.splitSections(output)
        if sections["missing"] != nil { return .missing }
        if sections["toolarge"] != nil { return .tooLarge }
        guard let meta = sections["meta"]?.first?.split(separator: " ", maxSplits: 2).map(String.init), meta.count == 3,
              let mtime = Int64(meta[0]) else { throw StackFileError.malformed("no ##meta") }
        guard let sha = sections["sha256"]?.first, sha.count == 64 else { throw StackFileError.malformed("no ##sha256") }
        // An empty file has an empty base64 line, which splitSections drops.
        let b64 = sections["content"]?.first ?? ""
        guard let data = Data(base64Encoded: b64) else { throw StackFileError.malformed("content is not base64") }
        guard let text = String(data: data, encoding: .utf8) else { throw StackFileError.notText }
        return .file(RemoteFile(content: text, sha256: sha, mode: meta[1], owner: meta[2], modifiedAt: mtime))
    }
}

/// Turns the text `docker compose config` prints into issues. Anything it prints on a failing run is an error;
/// `level=warning` log lines are warnings (they appear on success too, e.g. the obsolete `version` key).
public enum ComposeIssueParser {
    public static func parse(_ output: String) -> [ComposeIssue] {
        var issues: [ComposeIssue] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("##") { continue }
            if line.contains("level=warning") {
                issues.append(ComposeIssue(severity: .warning, line: nil, message: logMessage(line) ?? line))
                continue
            }
            if line.contains("level=info") || line.contains("level=debug") { continue }
            let (number, text) = split(line)
            issues.append(ComposeIssue(severity: .error, line: number, message: text))
        }
        return issues
    }

    /// Line numbers appear as `yaml: line 5: could not find expected ':'`, as an indented `line 3: field x not found`,
    /// and (newer compose) as `... go-yaml load error in scanner at L4.C12: mapping values are not allowed ...`.
    private static func split(_ line: String) -> (Int?, String) {
        if let range = line.range(of: #"\bL(\d+)\.C\d+:\s*"#, options: .regularExpression) {
            let number = line[range].dropFirst().prefix { $0.isNumber }
            let rest = String(line[range.upperBound...])
            return (Int(number), rest.isEmpty ? line : rest)
        }
        guard let range = line.range(of: #"(^|\s)line (\d+):\s*"#, options: .regularExpression) else { return (nil, line) }
        let head = line[range]
        let number = head.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) }
        var rest = String(line[range.upperBound...])
        if rest.isEmpty { rest = line }
        return (number, rest)
    }

    private static func logMessage(_ line: String) -> String? {
        guard let start = line.range(of: #"msg=""#) else { return nil }
        let tail = line[start.upperBound...]
        guard let end = tail.lastIndex(of: "\"") else { return nil }
        return String(tail[..<end]).replacingOccurrences(of: "\\\"", with: "\"")
    }
}
