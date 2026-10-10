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
    /// After `down` succeeded: leave `/`, then check, each guard with its own message (the containers are gone by then, so
    /// silence or a wrong reason would be confusing): the stack's compose file exists; the folder itself is not a symlink;
    /// the compose file's real path lies inside the folder's real path (so a symlink can't redirect the delete, while a
    /// symlinked PARENT such as /opt -> /mnt/data/opt is fine and deletes through it). Then remove the folder, with
    /// `sudo -n` as a second try for files a container created as root.
    static let folderStep = #" && cd / && { [ -f {file} ] || { echo 'The containers are removed, but the folder was left alone: its compose file is missing.'; exit 6; }; } && { [ ! -L {dir} ] || { echo 'The containers are removed, but the folder was left alone: it is a symbolic link.'; exit 6; }; } && R=$(readlink -f -- {dir}) && { case "$(readlink -f -- {file})" in "$R"/*) true;; *) echo 'The containers are removed, but the folder was left alone: its compose file is not inside it.'; exit 6;; esac; } && { rm -rf -- {dir} || { [ "$(id -u)" -ne 0 ] && sudo -n rm -rf -- {dir}; } || { echo 'The containers are removed, but the folder could not be deleted (permissions).'; exit 6; }; }"#
    public static let timeout: TimeInterval = 600

    /// True when anything beyond the containers and networks is removed, which is when the UI asks for the name.
    public var losesData: Bool { removeVolumes || deleteFolder }

    /// The compose files of a stack, in the same order the compose actions use them.
    static func composeFiles(of stack: DockerStack) -> [String] {
        stack.configFiles.isEmpty ? (stack.configFile.map { [$0] } ?? []) : stack.configFiles
    }

    /// Why the stack's folder can't be offered for deletion, or nil when it can.
    public static func folderProblem(for stack: DockerStack) -> String? {
        guard let dir = stack.workingDir, dir.hasPrefix("/") else { return "The stack's folder is unknown" }
        if let reason = unsafeFolderReason(dir) { return reason }
        let files = composeFiles(of: stack)
        let inside = files.allSatisfy { $0.hasPrefix(dir + "/") && isNormal($0) }
        if files.isEmpty || !inside { return "The compose files are not all inside that folder" }
        return nil
    }

    /// No empty, `.` or `..` parts, no doubled or trailing slashes.
    static func isNormal(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("//"), !path.hasSuffix("/") || path == "/" else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    /// System trees where nothing of a stack's belongs, and whole mount points and home folders.
    static let systemTrees = ["/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/boot", "/dev", "/proc", "/sys", "/etc", "/run",
                              "/snap", "/var/lib/docker", "/var/lib/containerd"]
    static let protectedFolders: Set<String> = ["/", "/home", "/root", "/opt", "/srv", "/mnt", "/media", "/tmp", "/var", "/data", "/Users",
                                                "/var/lib", "/var/log", "/var/tmp", "/var/www", "/var/opt", "/var/run", "/var/cache"]

    static func unsafeFolderReason(_ path: String) -> String? {
        guard isNormal(path) else { return "That folder path is not in a normal form" }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count < 2 { return "\(path) is too high up to delete" }
        if systemTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return "\(path) is a system folder" }
        if protectedFolders.contains(path) { return "\(path) is a system folder" }
        // /home/<user>, /Users/<user>, and the top level of a mount point (/mnt/<disk>, /media/<disk>).
        if parts.count == 2, ["home", "Users", "mnt", "media"].contains(parts[0]) { return "\(path) is a home folder or a mount point" }
        return nil
    }

    /// The exact command, or nil if the stack has no usable compose project or paths, or the folder step is not allowed.
    public func command(for stack: DockerStack) -> String? {
        var folder = ""
        if deleteFolder {
            guard Self.folderProblem(for: stack) == nil, let dir = stack.workingDir.flatMap(ShellQuote.quotePath),
                  let file = Self.composeFiles(of: stack).first.flatMap(ShellQuote.quotePath) else { return nil }
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
