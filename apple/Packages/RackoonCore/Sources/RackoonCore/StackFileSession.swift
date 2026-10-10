import Foundation

/// One edit of one file: what was opened, and what it should become. Describes the save for the policy and the
/// confirmation dialog (a readable diff, since the command itself carries the content encoded).
public struct FileEdit: Sendable, Equatable {
    public var file: EditableFile
    /// The file as it was opened (nil if it did not exist) and its hash.
    public var original: String?
    public var originalSHA: String?
    public var content: String

    public init(file: EditableFile, original: String?, originalSHA: String?, content: String) {
        self.file = file
        self.original = original
        self.originalSHA = originalSHA
        self.content = content
    }

    public var changeCount: Int { LineDiff.changeCount(old: original ?? "", new: content) }
}

/// Reads, checks and saves the files of one stack. Reads and checks change nothing; a save is a `.mutate` intent.
public actor StackFileSession {
    private let transport: SSHTransport
    private let policy: ActionPolicy
    private let stack: DockerStack

    public init(transport: SSHTransport, policy: ActionPolicy = ActionPolicy(), stack: DockerStack) {
        self.transport = transport
        self.policy = policy
        self.stack = stack
    }

    public nonisolated var files: [EditableFile] { StackFiles.editable(for: stack) ?? [] }

    public func read(_ file: EditableFile) async throws -> RemoteFileState {
        guard let command = StackFileCommands.read(file, in: stack) else { throw StackFileError.notEditable(file.path) }
        let result = try await transport.run(command, timeout: 20)
        guard result.exitCode == 0 else { throw StackFileError.commandFailed(Self.detail(result, fallback: "Could not read \(file.fileName)")) }
        return try RemoteFileParser.parse(result.stdout)
    }

    /// Asks the server whether `content` would work as `file`. Throws if the check itself could not run
    /// (no write access to the folder, ssh trouble); a file with errors is a normal result.
    public func validate(_ file: EditableFile, content: String) async throws -> ValidationResult {
        if content.utf8.count > StackFiles.maxBytes { throw StackFileError.tooLarge }
        guard let command = StackFileCommands.validate(file, content: content, in: stack) else { throw StackFileError.notEditable(file.path) }
        let result = try await transport.run(command, timeout: 60)
        if result.exitCode == 7 || result.stdout.contains("##cannot-write") { throw StackFileError.cannotWrite }
        let output = [result.stdout, result.stderr].joined(separator: "\n")
        let issues = ComposeIssueParser.parse(output).map { $0.naming(file) }
        // A non-zero exit with nothing parseable (e.g. docker missing) must not read as "valid".
        if result.exitCode != 0, !issues.contains(where: { $0.severity == .error }) {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ValidationResult(issues: issues + [ComposeIssue(severity: .error, line: nil,
                message: detail.isEmpty ? "docker compose config failed (exit \(result.exitCode))" : detail)])
        }
        return ValidationResult(issues: issues)
    }

    /// The intent for saving `edit`, with a readable diff as its preview. Pass the same edit to `save`.
    public nonisolated func intent(for edit: FileEdit) -> Intent? {
        guard let command = StackFileCommands.write(edit.file, content: edit.content, expectedSHA: edit.originalSHA, in: stack) else { return nil }
        return Intent(summary: "Save \(edit.file.fileName) on \(stack.name)", command: command, risk: .mutate,
                      preview: LineDiff.preview(old: edit.original ?? "", new: edit.content))
    }

    public nonisolated func confirm(_ edit: FileEdit) throws -> Confirmation {
        guard let intent = intent(for: edit) else { throw PolicyError.invalidTarget }
        return try policy.confirm(intent)
    }

    public func save(_ edit: FileEdit, confirmation: Confirmation?) async throws -> SaveOutcome {
        guard let intent = intent(for: edit) else { throw edit.content.utf8.count > StackFiles.maxBytes ? StackFileError.tooLarge : PolicyError.invalidTarget }
        try policy.authorize(intent, with: confirmation)
        let result = try await transport.run(intent.command, timeout: 90)
        let output = [result.stdout, result.stderr].joined(separator: "\n")
        switch result.exitCode {
        case 0:
            let lines = result.stdout.split(separator: "\n").map(String.init)
            guard let marker = lines.firstIndex(of: "##saved"), lines.indices.contains(marker + 1), lines[marker + 1].count == 64 else {
                throw StackFileError.malformed("save did not confirm")
            }
            return .saved(sha256: lines[marker + 1])
        case 3: return .changedOnServer
        case 4: return .invalid(ComposeIssueParser.parse(output).filter { $0.severity == .error }.map { $0.naming(edit.file) })
        case 7: throw StackFileError.cannotWrite
        default: throw StackFileError.commandFailed(Self.detail(result, fallback: "Saving failed (exit \(result.exitCode))"))
        }
    }

    private static func detail(_ result: CommandResult, fallback: String) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }
}
