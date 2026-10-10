import Foundation

/// Deleting a stack: `docker compose down --remove-orphans` (stops and removes its containers and the networks compose made
/// for it), and optionally its named volumes and its folder on the server. Images are never removed.
///
/// The folder step is the dangerous one, so it has its own rules: the folder must not be a system or home directory, every
/// compose file of the stack must live inside it, it only runs after `down` succeeded, and only if the stack's own compose
/// file is still there (so a wrong folder is never emptied).
public struct StackRemoval: Sendable, Equatable {
    /// Also remove the named volumes the compose file declares (`down -v`). Data in them is lost.
    public var removeVolumes: Bool
    /// Also delete the stack's folder: compose files, .env and everything else in it, including bind-mounted data.
    public var deleteFolder: Bool

    public init(removeVolumes: Bool = false, deleteFolder: Bool = false) {
        self.removeVolumes = removeVolumes
        self.deleteFolder = deleteFolder
    }

    /// Equals the script in spec/commands.json (`compose_down`); a test enforces it.
    static let template = "cd {dir} && docker compose -p {project} {files} down --remove-orphans{volumes}{folder}"
    static let folderStep = " && cd / && [ -f {file} ] && rm -rf -- {dir}"
    public static let timeout: TimeInterval = 600

    /// True when anything beyond the containers and networks is removed, which is when the UI asks for the name.
    public var losesData: Bool { removeVolumes || deleteFolder }

    /// Why the stack's folder can't be offered for deletion, or nil when it can.
    public static func folderProblem(for stack: DockerStack) -> String? {
        guard let dir = stack.workingDir, dir.hasPrefix("/") else { return "The stack's folder is unknown" }
        if let reason = unsafeFolderReason(dir) { return reason }
        let files = stack.configFiles.isEmpty ? (stack.configFile.map { [$0] } ?? []) : stack.configFiles
        if files.isEmpty || !files.allSatisfy({ $0.hasPrefix(dir + "/") }) { return "The compose files are not all inside that folder" }
        return nil
    }

    static func unsafeFolderReason(_ path: String) -> String? {
        guard !path.contains("//"), !path.hasSuffix("/") || path == "/" else { return "That folder path is not in a normal form" }
        let parts = path.split(separator: "/").map(String.init)
        if parts.isEmpty { return "That is the root folder" }
        if parts.contains("..") || parts.contains(".") { return "The folder path contains . or .." }
        let protected: Set<String> = ["/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib32", "/lib64", "/media", "/mnt", "/opt", "/proc",
                                      "/root", "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/var", "/usr/local", "/usr/share", "/usr/lib",
                                      "/usr/bin", "/var/lib", "/var/lib/docker", "/var/log", "/var/tmp", "/var/www", "/var/opt"]
        if protected.contains(path) { return "\(path) is a system folder" }
        if parts.count == 2, parts[0] == "home" { return "\(path) is a home folder" }
        return nil
    }

    /// The exact command, or nil if the stack has no usable compose project or paths, or the folder step is not allowed.
    public func command(for stack: DockerStack) -> String? {
        var folder = ""
        if deleteFolder {
            guard Self.folderProblem(for: stack) == nil, let dir = stack.workingDir.flatMap(ShellQuote.quotePath),
                  let file = (stack.configFile ?? stack.configFiles.first).flatMap(ShellQuote.quotePath) else { return nil }
            folder = Template.fill(Self.folderStep, ["file": file, "dir": dir])
        }
        return ComposeAction.fill(Self.template, stack: stack, extra: ["volumes": removeVolumes ? " -v" : "", "folder": folder])
    }

    public func intent(for stack: DockerStack) -> Intent? {
        guard let command = command(for: stack) else { return nil }
        let what = deleteFolder ? "Delete stack \(stack.name) and its folder" : "Delete stack \(stack.name)"
        return Intent(summary: what, command: command, risk: .mutate)
    }
}
