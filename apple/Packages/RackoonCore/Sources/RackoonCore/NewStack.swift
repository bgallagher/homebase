import Foundation

/// A compose stack that does not exist on the server yet: where it goes and what its files contain.
public struct NewStackPlan: Sendable, Equatable {
    public var name: String
    /// The folder that will hold the stack's own folder (e.g. `/opt/stacks`).
    public var parentDirectory: String
    public var compose: String
    /// Contents of `.env`; an empty string means no `.env` file is created.
    public var env: String

    public static let composeFileName = "compose.yaml"
    public static let starterCompose = """
    services:
      app:
        image: nginx:alpine
        restart: unless-stopped
        ports:
          - "8080:80"

    """

    public init(name: String = "", parentDirectory: String, compose: String = NewStackPlan.starterCompose, env: String = "") {
        self.name = name
        self.parentDirectory = parentDirectory
        self.compose = compose
        self.env = env
    }

    /// Why the name can't be used, or nil. It becomes the compose project name and the folder name.
    public var nameProblem: String? {
        if name.isEmpty { return "Enter a name" }
        if !DockerSession.isComposeProjectName(name) {
            return "Use lowercase letters, digits, - and _, starting with a letter or digit"
        }
        return nil
    }

    /// Why the folder can't be used, or nil.
    public var folderProblem: String? {
        let p = normalizedParent
        if !p.hasPrefix("/") { return "Enter an absolute path, such as /opt/stacks" }
        if p.split(separator: "/").contains("..") { return "The path can't contain .." }
        if ShellQuote.quotePath(p) == nil { return "That path can't be used" }
        return nil
    }

    var normalizedParent: String {
        var p = parentDirectory.trimmingCharacters(in: .whitespaces)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public var isValid: Bool { nameProblem == nil && folderProblem == nil }

    /// `<parent>/<name>`, or nil while the name or folder is not usable.
    public var directory: String? {
        guard isValid else { return nil }
        return normalizedParent == "/" ? "/" + name : normalizedParent + "/" + name
    }

    public var composePath: String? { directory.map { $0 + "/" + Self.composeFileName } }
    public var hasEnv: Bool { !env.isEmpty }

    /// The stack as the rest of the app sees it once created, with no containers yet. It lets the normal compose
    /// actions (`up -d`) run on it through the same validation as every other stack.
    public var stack: DockerStack? {
        guard let directory, let composePath else { return nil }
        return DockerStack(name: name, workingDir: directory, configFile: composePath, configFiles: [composePath],
                           containers: [], isStandalone: false)
    }
}

public enum NewStackDefaults {
    /// Where new stacks should go, learned from the server: the most common parent folder of the existing stacks'
    /// working directories. With none, `/opt/stacks` (what Dockge and most guides use) for root, or a `stacks` folder in
    /// the user's home so no sudo is needed.
    public static func parentDirectory(stacks: [DockerStack], user: String?) -> String {
        var counts: [String: Int] = [:]
        for stack in stacks where !stack.isStandalone {
            guard let dir = stack.workingDir, dir.hasPrefix("/") else { continue }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent != "/", !parent.isEmpty { counts[parent, default: 0] += 1 }
        }
        // Ties go to the shorter, then alphabetically first path, so the answer never flips between polls.
        if let best = counts.min(by: { a, b in
            a.value != b.value ? a.value > b.value : (a.key.count, a.key) < (b.key.count, b.key)
        }) { return best.key }
        if let user, !user.isEmpty, user != "root" { return "/home/\(user)/stacks" }
        return "/opt/stacks"
    }
}

/// Commands for creating a stack. Templates equal the scripts in spec/commands.json (`stack_new_check`,
/// `stack_create`); a test enforces it.
///
/// A check runs in a scratch folder and never touches the stack's real folder. Creating makes the folder
/// (refusing if the name is taken), writes the files, lets the server's `docker compose config` check them in
/// place, and removes everything it made if that fails, so a bad file leaves nothing behind.
public enum NewStackCommands {
    public static let checkTemplate = #"T=$(mktemp -d) || { echo '##cannot-write'; exit 7; }; trap 'rm -rf "$T"' EXIT; echo {b64} | base64 -d > "$T/compose.yaml"; {env}cd "$T" && docker compose -p {project} config -q 2>&1"#

    public static let createTemplate = #"D={dir}; P={parent}; if [ -e "$D" ]; then echo '##exists'; exit 3; fi; mkdir -p "$P" && mkdir "$D" || { echo '##cannot-write'; exit 7; }; ok=; trap '[ -n "$ok" ] || { rm -f "$D/compose.yaml" "$D/.env"; rmdir "$D" 2>/dev/null; }' EXIT; echo {b64} | base64 -d > "$D/compose.yaml" || exit 7; {env}if ! OUT=$(cd "$D" && docker compose -p {project} config -q 2>&1); then echo '##invalid'; echo "$OUT"; exit 4; fi; ok=1; echo '##created'"#

    static let checkEnvStep = #"echo {envb64} | base64 -d > "$T/.env"; "#
    static let createEnvStep = #"echo {envb64} | base64 -d > "$D/.env" && chmod 600 "$D/.env" || exit 7; "#

    public static func check(_ plan: NewStackPlan) -> String? {
        guard plan.nameProblem == nil, let parts = common(plan) else { return nil }
        return Template.fill(checkTemplate, ["b64": parts.b64, "project": plan.name,
                                             "env": parts.envB64.map { Template.fill(checkEnvStep, ["envb64": $0]) } ?? ""])
    }

    public static func create(_ plan: NewStackPlan) -> String? {
        guard let dir = plan.directory.flatMap(ShellQuote.quotePath), let parent = ShellQuote.quotePath(plan.normalizedParent),
              let parts = common(plan) else { return nil }
        return Template.fill(createTemplate, ["dir": dir, "parent": parent, "b64": parts.b64, "project": plan.name,
                                              "env": parts.envB64.map { Template.fill(createEnvStep, ["envb64": $0]) } ?? ""])
    }

    private static func common(_ plan: NewStackPlan) -> (b64: String, envB64: String?)? {
        guard plan.compose.utf8.count <= StackFiles.maxBytes, plan.env.utf8.count <= StackFiles.maxBytes else { return nil }
        // An empty file encodes to an empty string, which `quote` refuses; it is just `''` here.
        guard let b64 = plan.compose.isEmpty ? "''" : ShellQuote.quote(Data(plan.compose.utf8).base64EncodedString()) else { return nil }
        if plan.env.isEmpty { return (b64, nil) }
        guard let envB64 = ShellQuote.quote(Data(plan.env.utf8).base64EncodedString()) else { return nil }
        return (b64, envB64)
    }
}

public enum NewStackOutcome: Sendable, Equatable {
    case created
    /// Something already exists at `<parent>/<name>`. Nothing was written.
    case exists
    /// The server's compose check refused the files. Everything that had been made was removed.
    case invalid([ComposeIssue])
}

/// Checks and creates a new stack's folder and files. A check changes nothing; creating is a `.mutate` intent.
public actor NewStackSession {
    private let transport: SSHTransport
    private let policy: ActionPolicy

    public init(transport: SSHTransport, policy: ActionPolicy = ActionPolicy()) {
        self.transport = transport
        self.policy = policy
    }

    /// Asks the server whether the files would work. Throws if the check itself could not run.
    public func check(_ plan: NewStackPlan) async throws -> ValidationResult {
        if plan.compose.utf8.count > StackFiles.maxBytes || plan.env.utf8.count > StackFiles.maxBytes { throw StackFileError.tooLarge }
        guard let command = NewStackCommands.check(plan) else { throw PolicyError.invalidTarget }
        let result = try await transport.run(command, timeout: 60)
        if result.exitCode == 7 || result.stdout.contains("##cannot-write") { throw StackFileError.cannotWrite }
        let output = [result.stdout, result.stderr].joined(separator: "\n")
        let issues = ComposeIssueParser.parse(output).map { $0.simplifyingScratchPaths() }
        if result.exitCode != 0, !issues.contains(where: { $0.severity == .error }) {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return ValidationResult(issues: issues + [ComposeIssue(severity: .error, line: nil,
                message: detail.isEmpty ? "docker compose config failed (exit \(result.exitCode))" : detail)])
        }
        return ValidationResult(issues: issues)
    }

    /// The intent for creating `plan`, with a readable summary as its preview (the command carries the files encoded).
    public nonisolated func intent(for plan: NewStackPlan) -> Intent? {
        guard let command = NewStackCommands.create(plan), let directory = plan.directory else { return nil }
        var lines = ["Create folder \(directory)", "+ \(NewStackPlan.composeFileName)"]
        if plan.hasEnv { lines.append("+ .env (readable only by its owner)") }
        let preview = lines.joined(separator: "\n") + "\n\n" + LineDiff.preview(old: "", new: plan.compose)
        return Intent(summary: "Create stack \(plan.name)", command: command, risk: .mutate, preview: preview)
    }

    public nonisolated func confirm(_ plan: NewStackPlan) throws -> Confirmation {
        guard let intent = intent(for: plan) else { throw PolicyError.invalidTarget }
        return try policy.confirm(intent)
    }

    public func create(_ plan: NewStackPlan, confirmation: Confirmation?) async throws -> NewStackOutcome {
        guard let intent = intent(for: plan) else {
            throw plan.compose.utf8.count > StackFiles.maxBytes ? StackFileError.tooLarge : PolicyError.invalidTarget
        }
        try policy.authorize(intent, with: confirmation)
        let result = try await transport.run(intent.command, timeout: 90)
        let output = [result.stdout, result.stderr].joined(separator: "\n")
        switch result.exitCode {
        case 0:
            guard result.stdout.contains("##created") else { throw StackFileError.malformed("creating did not confirm") }
            return .created
        case 3: return .exists
        case 4: return .invalid(ComposeIssueParser.parse(output).filter { $0.severity == .error }.map { $0.simplifyingScratchPaths() })
        case 7: throw StackFileError.cannotWrite
        default:
            let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StackFileError.commandFailed(text.isEmpty ? "Creating the stack failed (exit \(result.exitCode))" : text)
        }
    }
}

extension ComposeIssue {
    /// Compose names the file by its full path (the scratch folder, or the new stack's folder). The editor only has
    /// `compose.yaml` and `.env`, so show those.
    func simplifyingScratchPaths() -> ComposeIssue {
        var copy = self
        copy.message = message.replacingOccurrences(of: #"[^\s:"']*/(compose\.yaml|\.env)"#, with: "$1", options: .regularExpression)
        return copy
    }
}
