import Foundation

public enum FolderEntryKind: String, Sendable, Equatable {
    case file, directory, symlink, other
}

/// One entry of a remote folder, from `RemoteFiles.listCommand`.
public struct FolderEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let kind: FolderEntryKind
    /// Where a symlink points (as written), nil for anything else.
    public let linkTarget: String?
    /// A symlink whose target is a folder behaves like a folder when browsing.
    public let linksToDirectory: Bool
    public let size: Int64
    public let modified: Date
    /// As `ls -l` prints it, e.g. `drwxr-xr-x`.
    public let permissions: String
    public let owner: String

    public var isDirectory: Bool { kind == .directory || linksToDirectory }
}

public struct RemoteListing: Sendable, Equatable {
    /// The folder's real path (symlinks resolved), which is what the pane should show.
    public let path: String
    public let entries: [FolderEntry]
    /// More entries existed than `RemoteFiles.maxEntries`.
    public let truncated: Bool
}

public enum RemoteFilesError: Error, Equatable, LocalizedError {
    case invalidPath
    case notFound(String)
    case permissionDenied(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "That is not a usable folder path."
        case .notFound(let p): "\(p) doesn't exist on the server."
        case .permissionDenied(let p): "You don't have permission to open \(p)."
        case .unreadable(let detail): "Couldn't read the folder: \(detail)"
        }
    }
}

/// Paths on the server: always absolute, `/` separated.
public enum RemotePath {
    public static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// `/` has no parent.
    public static func parent(of path: String) -> String? {
        guard path != "/", path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
        return "/" + parts.joined(separator: "/")
    }

    /// Breadcrumb pieces from the root down: `/opt/stacks` -> [("/", "/"), ("opt", "/opt"), ("stacks", "/opt/stacks")].
    public static func crumbs(_ path: String) -> [(name: String, path: String)] {
        var out: [(String, String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + part
            out.append((String(part), current))
        }
        return out
    }
}

/// The read-only side of the Files screen: list a folder on the server. The script equals spec/commands.json
/// (`files_list`). It needs GNU find (`-printf`), which Debian and Ubuntu have; names are NUL separated, so any file
/// name (spaces, newlines, quotes) survives.
public enum RemoteFiles {
    /// Folders with more entries than this are cut off (and say so).
    public static let maxEntries = 5000

    public static let listTemplate =
        #"cd -P -- {dir} 2>/dev/null || exit 3; [ -r . ] && [ -x . ] || exit 4; printf '%s\0' "$PWD"; find . -mindepth 1 -maxdepth 1 -printf '%y\0%Y\0%s\0%T@\0%M\0%u\0%f\0%l\0' 2>/dev/null"#

    /// Where browsing starts: the ssh user's home (ssh commands start there), resolved.
    public static let homeCommand = "pwd -P"

    /// Opens a login shell in `directory` (for a terminal tab running `ssh -t host <this>`).
    public static func terminalCommand(in directory: String) -> String? {
        ShellQuote.quotePath(directory).map { "cd \($0) && exec \"${SHELL:-/bin/sh}\" -l" }
    }

    public static func listCommand(_ directory: String) -> String? {
        guard let dir = ShellQuote.quotePath(directory) else { return nil }
        return Template.fill(listTemplate, ["dir": dir])
    }

    /// First field is the folder's real path, then eight fields per entry: type, type after following links, size,
    /// modified (epoch seconds), permissions, owner, name, link target.
    public static func parseListing(_ output: String) -> RemoteListing? {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // The output ends with a NUL, which leaves one empty piece.
        if fields.last == "" { fields.removeLast() }
        guard let path = fields.first, path.hasPrefix("/") else { return nil }
        let rest = fields.dropFirst()
        var entries: [FolderEntry] = []
        var index = rest.startIndex
        var truncated = false
        while rest.distance(from: index, to: rest.endIndex) >= 8 {
            let f = Array(rest[index..<rest.index(index, offsetBy: 8)])
            index = rest.index(index, offsetBy: 8)
            if entries.count >= maxEntries { truncated = true; break }
            let kind: FolderEntryKind = switch f[0] {
            case "f": .file
            case "d": .directory
            case "l": .symlink
            default: .other
            }
            entries.append(FolderEntry(
                name: f[6], kind: kind,
                linkTarget: kind == .symlink && !f[7].isEmpty ? f[7] : nil,
                linksToDirectory: kind == .symlink && f[1] == "d",
                size: Int64(f[2]) ?? 0,
                modified: Date(timeIntervalSince1970: Double(f[3]) ?? 0),
                permissions: f[4], owner: f[5]))
        }
        return RemoteListing(path: path, entries: entries, truncated: truncated)
    }

    static func error(exitCode: Int32, stderr: String, path: String) -> RemoteFilesError {
        switch exitCode {
        case 3: .notFound(path)
        case 4: .permissionDenied(path)
        default: .unreadable(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "the server answered with status \(exitCode)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

// MARK: - Transfers

/// Something on this Mac to send to the server.
///
/// `bytes` is exactly how many bytes will be sent (the file's size, or the size of the folder's tar stream). The server
/// checks it before moving anything into place, because a cancelled or dropped upload looks like a normal end of input
/// to the remote command and would otherwise leave a half-written file under the real name.
public enum LocalSource: Sendable, Equatable {
    case file(URL, bytes: Int64)
    /// A folder, sent as a tar stream of `<name>/...`.
    case folder(URL, bytes: Int64)

    public var url: URL {
        switch self { case .file(let u, _), .folder(let u, _): u }
    }
    public var bytes: Int64 {
        switch self { case .file(_, let b), .folder(_, let b): b }
    }
}

/// Where to put what the server sends.
public enum LocalSink: Sendable, Equatable {
    case file(URL)
    /// Extracts a tar stream into this existing folder.
    case folder(into: URL)
}

/// Moves bytes between this Mac and a command running on the server (the app's SSH layer implements it). Progress
/// reports the bytes moved so far. Cancelling the calling task stops both ends.
public protocol FileTransferring: Sendable {
    func upload(_ source: LocalSource, remoteCommand: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    func download(remoteCommand: String, to sink: LocalSink, progress: @escaping @Sendable (Int64) -> Void) async throws
}

public enum TransferError: Error, Equatable, LocalizedError {
    case badName(String)
    case failed(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .badName(let n): "“\(n)” has a character in its name that can't be sent safely."
        case .failed(let detail): detail
        case .unavailable: "File transfers aren't available for this connection."
        }
    }
}

/// The commands that move files; templates equal spec/commands.json (`files_upload_file`, `files_upload_folder`,
/// `files_download_file`, `files_download_folder`). File content travels on the command's stdin or stdout, never inside
/// the command text.
public enum FileTransferCommands {
    /// Writes stdin to a temporary file beside the target and moves it into place, so a failed or cancelled upload never
    /// leaves half a file under the real name. An existing file keeps its owner and mode. Refuses a folder in the way.
    public static let uploadFileTemplate =
        #"D={dest}; T={tmp}; if [ -d "$D" ]; then echo 'A folder with that name already exists.' >&2; exit 5; fi; cat > "$T" || { rm -f -- "$T"; exit 1; }; if [ "$(wc -c < "$T")" -ne {bytes} ]; then rm -f -- "$T"; echo 'The upload was interrupted, so nothing was changed.' >&2; exit 1; fi; if [ -e "$D" ]; then chmod --reference="$D" "$T" 2>/dev/null; chown --reference="$D" "$T" 2>/dev/null; fi; mv -f -- "$T" "$D" || { rm -f -- "$T"; exit 1; }"#

    /// Receives a tar stream (which holds `{src}/...`) into a scratch folder inside the destination folder, checks it is
    /// {bytes} long (else nothing is touched), unpacks it, then moves the folder to `{dest}`; if `{dest}` is already a
    /// folder its contents are merged in. Files are owned by the ssh user. The scratch folder is always removed.
    public static let uploadFolderTemplate =
        #"T=$(mktemp -d {tmpdir}) || exit 1; mkdir "$T/x"; cat > "$T/in.tar"; if [ "$(wc -c < "$T/in.tar")" -ne {bytes} ]; then echo 'The upload was interrupted, so nothing was changed.' >&2; rc=1; else tar -xf "$T/in.tar" -C "$T/x" --no-same-owner; rc=$?; if [ $rc -eq 0 ]; then if [ -d {dest} ]; then cp -a -- "$T"/x/{src}/. {dest}/; else mv -- "$T"/x/{src} {dest}; fi; rc=$?; fi; fi; rm -rf -- "$T"; exit $rc"#

    public static let downloadFileTemplate = "cat -- {path}"
    /// Archives the folder's CONTENTS (`cd` follows a link, so `current -> releases/v3` sends the folder it points to,
    /// while links inside the folder stay links). The app unpacks them into a folder named after the entry.
    public static let downloadFolderTemplate = "tar -C {path} -cf - ."

    /// `newName` is the name on the server (it differs from the local name for "keep both").
    /// The temporary name adds 14 bytes (`.` + `.rackoon-part`), and file names are limited to 255.
    static let maxUploadNameBytes = 240

    public static func uploadFile(directory: String, newName: String, bytes: Int64) -> String? {
        guard validName(newName), newName.utf8.count <= maxUploadNameBytes, let dest = ShellQuote.quotePath(RemotePath.join(directory, newName)),
              let tmp = ShellQuote.quotePath(RemotePath.join(directory, ".\(newName).rackoon-part")) else { return nil }
        return Template.fill(uploadFileTemplate, ["dest": dest, "tmp": tmp, "bytes": String(bytes)])
    }

    public static func uploadFolder(directory: String, sourceName: String, newName: String, bytes: Int64) -> String? {
        guard validName(sourceName), validName(newName), let dest = ShellQuote.quotePath(RemotePath.join(directory, newName)),
              let src = ShellQuote.quote(sourceName), let tmpdir = ShellQuote.quotePath(RemotePath.join(directory, ".rackoon-XXXXXX"))
        else { return nil }
        return Template.fill(uploadFolderTemplate, ["tmpdir": tmpdir, "dest": dest, "src": src, "bytes": String(bytes)])
    }

    public static func downloadFile(directory: String, name: String) -> String? {
        guard validName(name), let path = ShellQuote.quotePath(RemotePath.join(directory, name)) else { return nil }
        return Template.fill(downloadFileTemplate, ["path": path])
    }

    public static func downloadFolder(directory: String, name: String) -> String? {
        guard validName(name), let path = ShellQuote.quotePath(RemotePath.join(directory, name)) else { return nil }
        return Template.fill(downloadFolderTemplate, ["path": path])
    }

    /// A name that can be one path component and one shell word.
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && ShellQuote.quote(name) != nil
    }
}

// MARK: - New folder, rename, delete

/// A change to the server's files. Each is a `.mutate` intent: Read-only blocks it and the user confirms the exact command.
public enum FileOperation: Sendable, Equatable {
    case makeFolder(in: String, name: String)
    case rename(in: String, from: String, to: String)
    case delete(in: String, name: String, isFolder: Bool)

    public var summary: String {
        switch self {
        case .makeFolder(let d, let n): "Create folder \(n) in \(d)"
        case .rename(let d, let f, let t): "Rename \(f) to \(t) in \(d)"
        case .delete(let d, let n, let folder): "Delete \(folder ? "folder" : "file") \(n) in \(d)"
        }
    }
}

public enum FileOperationCommands {
    /// Fails (exit 5) rather than reuse a name that is taken, and never creates parents.
    public static let makeFolderTemplate = #"if [ -e {path} ] || [ -L {path} ]; then echo 'That name is already taken.' >&2; exit 5; fi; mkdir -- {path}"#
    /// Never replaces an existing entry (exit 5).
    public static let renameTemplate = #"if [ -e {to} ] || [ -L {to} ]; then echo 'That name is already taken.' >&2; exit 5; fi; mv -- {from} {to}"#
    /// A file or a symlink (a link is removed, never followed).
    public static let deleteFileTemplate = "rm -f -- {path}"
    /// A folder and everything in it. Only offered for folders `deleteProblem` accepts.
    public static let deleteFolderTemplate = "rm -rf -- {path}"

    /// Why a folder can't be deleted from here, or nil. Stricter than the stack delete: nothing shallower than three levels
    /// (so /opt/stacks and /srv/data stay out of reach; use a terminal for those).
    public static func deleteProblem(folder path: String) -> String? {
        if let reason = StackRemoval.unsafeFolderReason(path) { return reason }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count < 3 { return "\(path) is too high up to delete from here. Use a terminal if you really mean it." }
        // Where databases and services keep their data, and a user's own dot folders (.ssh, .config, .gnupg...).
        if parts[0] == "var", ["lib", "www", "mail", "spool", "backups"].contains(parts[1]), parts.count < 4 || parts[1] == "lib" {
            return "\(path) holds service data. Use a terminal if you really mean it."
        }
        if ["home", "Users"].contains(parts[0]), parts.count == 3, parts[2].hasPrefix(".") { return "\(path) is a settings folder in a home folder" }
        if parts[0] == "root", parts.count == 2 { return "\(path) is a settings folder in a home folder" }
        return nil
    }

    public static func command(for op: FileOperation) -> String? {
        switch op {
        case .makeFolder(let dir, let name):
            guard FileTransferCommands.validName(name), let path = ShellQuote.quotePath(RemotePath.join(dir, name)) else { return nil }
            return Template.fill(makeFolderTemplate, ["path": path])
        case .rename(let dir, let from, let to):
            guard FileTransferCommands.validName(from), FileTransferCommands.validName(to), from != to,
                  let f = ShellQuote.quotePath(RemotePath.join(dir, from)), let t = ShellQuote.quotePath(RemotePath.join(dir, to)) else { return nil }
            return Template.fill(renameTemplate, ["from": f, "to": t])
        case .delete(let dir, let name, let isFolder):
            guard FileTransferCommands.validName(name), let path = ShellQuote.quotePath(RemotePath.join(dir, name)) else { return nil }
            if isFolder {
                guard deleteProblem(folder: RemotePath.join(dir, name)) == nil else { return nil }
                return Template.fill(deleteFolderTemplate, ["path": path])
            }
            return Template.fill(deleteFileTemplate, ["path": path])
        }
    }
}

/// Lists folders and moves files on one server. Listing and downloads only read; uploads are `.mutate` intents that need
/// read-only mode off and a `Confirmation` for that exact intent, like every other change.
public struct FilesSession: Sendable {
    private let transport: SSHTransport
    private let transfers: FileTransferring?
    private let policy: ActionPolicy

    public init(transport: SSHTransport, transfers: FileTransferring? = nil, policy: ActionPolicy = ActionPolicy()) {
        self.transport = transport
        self.transfers = transfers
        self.policy = policy
    }

    public func homeDirectory() async -> String? {
        guard let result = try? await transport.run(RemoteFiles.homeCommand, timeout: 10), result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    public func list(_ directory: String) async throws -> RemoteListing {
        guard let command = RemoteFiles.listCommand(directory) else { throw RemoteFilesError.invalidPath }
        let result = try await transport.run(command, timeout: 20)
        guard result.exitCode == 0 else {
            throw RemoteFiles.error(exitCode: result.exitCode, stderr: result.stderr, path: directory)
        }
        guard let listing = RemoteFiles.parseListing(result.stdout) else {
            throw RemoteFilesError.unreadable("the answer wasn't a folder listing")
        }
        return listing
    }

    // MARK: upload

    public func uploadIntent(_ source: LocalSource, toDirectory directory: String, as newName: String) -> Intent? {
        let local = source.url.lastPathComponent, command: String?
        switch source {
        case .file: command = FileTransferCommands.uploadFile(directory: directory, newName: newName, bytes: source.bytes)
        case .folder: command = FileTransferCommands.uploadFolder(directory: directory, sourceName: local, newName: newName, bytes: source.bytes)
        }
        guard let command else { return nil }
        return Intent(summary: "Upload \(local) to \(directory)", command: command, risk: .mutate)
    }

    public nonisolated func confirm(_ intent: Intent) throws -> Confirmation { try policy.confirm(intent) }

    public func upload(_ source: LocalSource, toDirectory directory: String, as newName: String, confirmation: Confirmation?,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        let name = source.url.lastPathComponent
        guard let intent = uploadIntent(source, toDirectory: directory, as: newName) else { throw TransferError.badName(name) }
        try policy.authorize(intent, with: confirmation)
        guard let transfers else { throw TransferError.unavailable }
        try await transfers.upload(source, remoteCommand: intent.command, progress: progress)
    }

    /// Moves a finished download into place. Replacing swaps it in atomically, so a failure keeps the old item.
    private static func place(_ new: URL, at final: URL, replacing: Bool) throws {
        let fm = FileManager.default
        if replacing, fm.fileExists(atPath: final.path) {
            _ = try fm.replaceItemAt(final, withItemAt: new)
        } else {
            try fm.moveItem(at: new, to: final)
        }
    }

    // MARK: download (reads only)

    /// Downloads `name` from `directory` into the local folder `localDirectory` as `localName`. The data goes to a
    /// temporary name first and is moved into place when complete, so a cancelled download leaves nothing under the real name.
    public func download(name: String, isDirectory: Bool, from directory: String, toLocalDirectory localDirectory: URL, as localName: String,
                         replacing: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard FileTransferCommands.validName(localName) else { throw TransferError.badName(localName) }
        guard let transfers else { throw TransferError.unavailable }
        let fm = FileManager.default
        let final = localDirectory.appendingPathComponent(localName, isDirectory: isDirectory)
        let scratch = localDirectory.appendingPathComponent(".rackoon-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: scratch) }
        if isDirectory {
            guard let command = FileTransferCommands.downloadFolder(directory: directory, name: name) else { throw TransferError.badName(name) }
            let extracted = scratch.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            try await transfers.download(remoteCommand: command, to: .folder(into: extracted), progress: progress)
            try Self.place(extracted, at: final, replacing: replacing)
        } else {
            guard let command = FileTransferCommands.downloadFile(directory: directory, name: name) else { throw TransferError.badName(name) }
            try await transfers.download(remoteCommand: command, to: .file(scratch), progress: progress)
            try Self.place(scratch, at: final, replacing: replacing)
        }
    }

    // MARK: new folder, rename, delete

    public func intent(for op: FileOperation) -> Intent? {
        FileOperationCommands.command(for: op).map { Intent(summary: op.summary, command: $0, risk: .mutate) }
    }

    public func perform(_ op: FileOperation, confirmation: Confirmation?) async throws {
        guard let intent = intent(for: op) else { throw TransferError.failed("That change can't be made safely from here.") }
        try policy.authorize(intent, with: confirmation)
        let result = try await transport.run(intent.command, timeout: 120)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TransferError.failed(detail.isEmpty ? "The server answered with status \(result.exitCode)." : detail)
        }
    }
}
