import AppKit
import Foundation
import Observation
import RackoonCore
import RackoonSSHSystem
import UniformTypeIdentifiers

/// One copy in the transfer list.
@MainActor @Observable
final class FileTransfer: Identifiable {
    enum Direction { case upload, download }
    enum State: Equatable { case waiting, running, done, failed(String), cancelled }

    nonisolated let id = UUID()
    let name: String
    let direction: Direction
    let destination: String
    private(set) var bytes: Int64 = 0
    /// Nil while unknown (a folder coming down): the bar then shows bytes only.
    private(set) var total: Int64?
    private(set) var state: State = .waiting
    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate let work: (FileTransfer) async throws -> Void

    init(name: String, direction: Direction, destination: String, total: Int64?, work: @escaping (FileTransfer) async throws -> Void) {
        self.name = name; self.direction = direction; self.destination = destination; self.total = total; self.work = work
    }

    var isFinished: Bool { if case .running = state { false } else if case .waiting = state { false } else { true } }
    var fraction: Double? { total.flatMap { $0 > 0 ? min(1, Double(bytes) / Double($0)) : nil } }
    func setProgress(_ b: Int64) { bytes = b }
    func setTotal(_ t: Int64?) { total = t }
    func set(_ s: State) { state = s }
    func cancel() { task?.cancel(); if state == .waiting { state = .cancelled } }
}

/// What the user must decide before a copy starts: some names already exist at the destination.
struct FileConflict: Identifiable {
    let id = UUID()
    let direction: FileTransfer.Direction
    let names: [String]
    /// Applies the decision: replace the existing ones, keep both (copies get a new name), or skip the existing ones.
    let resolve: (Resolution) -> Void
    enum Resolution { case replace, keepBoth, skipExisting }
}

/// The Files screen's state for one server: a local pane, a remote pane and the transfer list. Owned by `DockerWorkspace`,
/// so the folders you were in and any running transfer survive switching screens.
@MainActor @Observable
final class FilesModel {
    let serverName: String
    let local: FilePane
    let remote: FilePane
    private(set) var transfers: [FileTransfer] = []
    var conflict: FileConflict?
    var pending: PendingAction?
    /// Why a copy couldn't start (read-only, nothing selected...).
    var notice: String?
    /// Measuring folders before the confirm sheet can show.
    private(set) var preparing = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private let session: FilesSession
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(server: Server) {
        serverName = server.name
        session = FilesSession(transport: makeTransport(for: server), transfers: makeTransfers(for: server), policy: SafetyStore.shared.policy)
        let session = session
        local = FilePane(path: NSHomeDirectory(), showHidden: false, loader: Self.listLocal)
        remote = FilePane(path: "/", showHidden: true) { path in
            let listing = try await session.list(path)
            return FolderContents(path: listing.path, rows: listing.entries.map(FileRow.init), truncated: listing.truncated)
        }
    }

    /// Loads both panes the first time the screen is shown (the remote one starts in the ssh user's home).
    func start() {
        guard !started else { return }
        started = true
        local.open(NSHomeDirectory())
        let remote = remote, session = session
        Task {
            let home = await session.homeDirectory() ?? "/"
            remote.open(home)
        }
    }

    var hasFinished: Bool { transfers.contains(where: \.isFinished) }
    var isBusy: Bool { transfers.contains { !$0.isFinished } }

    func clearFinished() { transfers.removeAll(where: \.isFinished) }

    // MARK: upload (this Mac -> server)

    func canUpload(_ names: Set<String>) -> String? {
        if SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if names.subtracting([".."]).isEmpty { return "Select something on this Mac first" }
        return nil
    }

    /// Something on this Mac to send: a row of the Mac pane, or a file dropped from Finder.
    struct LocalItem {
        let url: URL
        let isDirectory: Bool
        let size: Int64?
        var name: String { url.lastPathComponent }
    }

    func upload(_ names: Set<String>) {
        notice = nil
        if let why = canUpload(names) { notice = why; return }
        let base = URL(fileURLWithPath: local.path)
        upload(items: local.rows.filter { names.contains($0.name) }.map {
            LocalItem(url: base.appendingPathComponent($0.name, isDirectory: $0.isDirectory), isDirectory: $0.isDirectory, size: $0.size)
        })
    }

    /// Files dropped on the server pane (from Finder). Anything inside the Mac pane's own folder came from there already.
    func upload(urls: [URL]) {
        notice = nil
        if let why = canUpload(["x"]) { notice = why; return }
        let items = urls.compactMap { url -> LocalItem? in
            guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
            return LocalItem(url: url, isDirectory: v.isDirectory ?? false, size: v.isDirectory == true ? nil : Int64(v.fileSize ?? 0))
        }
        guard !items.isEmpty else { return }
        upload(items: items)
    }

    private func upload(items: [LocalItem]) {
        let existing = Set(remote.rows.map(\.name))
        let clashes = items.map(\.name).filter(existing.contains).sorted()
        let destination = remote.path
        let go: (FileConflict.Resolution?) -> Void = { [self] resolution in
            var plan: [(row: LocalItem, target: String)] = []
            for row in items {
                if existing.contains(row.name) {
                    switch resolution {
                    case .replace?: plan.append((row, row.name))
                    case .keepBoth?: plan.append((row, Self.copyName(row.name, avoiding: existing.union(plan.map(\.target)))))
                    default: break
                    }
                } else { plan.append((row, row.name)) }
            }
            confirmUpload(plan, to: destination, replacing: resolution == .replace ? Set(clashes) : [])
        }
        if clashes.isEmpty { go(nil) }
        else { conflict = FileConflict(direction: .upload, names: clashes, resolve: { go($0) }) }
    }

    private func confirmUpload(_ plan: [(row: LocalItem, target: String)], to directory: String, replacing: Set<String>) {
        guard !plan.isEmpty else { return }
        let session = session
        preparing = true
        Task {
            defer { preparing = false }
            var jobs: [(row: LocalItem, target: String, source: LocalSource, intent: Intent)] = []
            for (row, target) in plan {
                let url = row.url
                let source: LocalSource
                do {
                    if row.isDirectory {
                        // The server checks the exact size of what arrives, so measure the folder's archive first.
                        let bytes = try await Task.detached { try LocalArchive.size(of: url) }.value
                        source = .folder(url, bytes: bytes)
                    } else {
                        source = .file(url, bytes: row.size ?? 0)
                    }
                } catch {
                    notice = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    return
                }
                guard let intent = session.uploadIntent(source, toDirectory: directory, as: target) else {
                    notice = "“\(row.name)” has a character in its name that can't be sent safely."
                    return
                }
                jobs.append((row, target, source, intent))
            }
            let lines = jobs.map { job in
                "• \(job.row.name)\(job.target == job.row.name ? "" : " as \(job.target)") → \(directory)" + (replacing.contains(job.row.name) ? (job.row.isDirectory ? "  (merges into the existing folder)" : "  (replaces the existing file)") : "")
            }
            pending = PendingAction(
                title: "Upload \(jobs.count == 1 ? "“\(jobs[0].row.name)”" : "\(jobs.count) items") to \(serverName)?",
                message: "Copies from this Mac to \(directory) on \(serverName). Files are written under a temporary name first and moved into place only when complete, so a failed or cancelled upload leaves no half file.",
                serverName: serverName, command: jobs.map(\.intent.command).joined(separator: "\n"), destructive: !replacing.isEmpty,
                preview: lines.joined(separator: "\n"),
                run: { [weak self] in
                    guard let self else { return }
                    for job in jobs { enqueueUpload(job.row, source: job.source, target: job.target, intent: job.intent, directory: directory) }
                })
        }
    }

    private func enqueueUpload(_ row: LocalItem, source: LocalSource, target: String, intent: Intent, directory: String) {
        let session = session
        let transfer = FileTransfer(name: row.name, direction: .upload, destination: directory, total: source.bytes) { transfer in
            let confirmation = try session.confirm(intent)
            try await session.upload(source, toDirectory: directory, as: target, confirmation: confirmation,
                                     progress: { b in Task { @MainActor in transfer.setProgress(b) } })
        }
        add(transfer, reload: remote, folder: directory)
    }

    // MARK: download (server -> this Mac)

    func download(_ names: Set<String>) {
        notice = nil
        let items = remote.rows.filter { names.contains($0.name) }
        guard !items.isEmpty else { notice = "Select something on \(serverName) first"; return }
        let directory = remote.path, destination = URL(fileURLWithPath: local.path)
        let existing = Set(local.rows.map(\.name))
        let clashes = items.map(\.name).filter(existing.contains).sorted()
        let go: (FileConflict.Resolution?) -> Void = { [self] resolution in
            var taken = existing
            for row in items {
                var target = row.name
                var replacing = false
                if existing.contains(row.name) {
                    switch resolution {
                    case .replace?: replacing = true
                    case .keepBoth?: target = Self.copyName(row.name, avoiding: taken)
                    default: continue
                    }
                }
                taken.insert(target)
                enqueueDownload(row, from: directory, to: destination, as: target, replacing: replacing)
            }
        }
        if clashes.isEmpty { go(nil) }
        else { conflict = FileConflict(direction: .download, names: clashes, resolve: { go($0) }) }
    }

    private func enqueueDownload(_ row: FileRow, from directory: String, to destination: URL, as target: String, replacing: Bool) {
        let session = session
        let transfer = FileTransfer(name: row.name, direction: .download, destination: destination.path, total: row.isDirectory ? nil : row.size) { transfer in
            try await session.download(name: row.name, isDirectory: row.isDirectory, from: directory, toLocalDirectory: destination,
                                       as: target, replacing: replacing, progress: { b in Task { @MainActor in transfer.setProgress(b) } })
        }
        add(transfer, reload: local, folder: destination.path)
    }

    // MARK: new folder, rename, delete

    /// A question with one text field (a folder name, a new name).
    struct NamePrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String?
        let initial: String
        let action: String
        /// Why the typed name can't be used, or nil.
        let problem: (String) -> String?
        /// The command that will run for this name, shown under the field (server only).
        let command: (String) -> String?
        let run: (String) -> Void
    }

    /// What the delete sheet shows. `problems` non-empty means nothing can be deleted.
    struct DeletePrompt: Identifiable {
        let id = UUID()
        let directory: String
        let items: [(name: String, isFolder: Bool)]
        let commands: [String]
        let problems: [String]
        let run: () -> Void
        var hasFolder: Bool { items.contains { $0.isFolder } }
    }

    var namePrompt: NamePrompt?
    var deletePrompt: DeletePrompt?

    func blockedReasonForServerChanges() -> String? { SafetyStore.shared.readOnly ? "Read-only mode is on" : nil }

    func newServerFolder() {
        notice = nil
        if let why = blockedReasonForServerChanges() { notice = why; return }
        let directory = remote.path, taken = Set(remote.rows.map(\.name)), session = session
        namePrompt = NamePrompt(
            title: "New folder on \(serverName)", message: "In \(directory)", initial: "", action: "Create",
            problem: { name in Self.nameProblem(name, taken: taken) },
            command: { FileOperationCommands.command(for: .makeFolder(in: directory, name: $0)) },
            run: { [self] name in runServerChange(.makeFolder(in: directory, name: name), session: session) })
    }

    func renameOnServer(_ name: String) {
        notice = nil
        if let why = blockedReasonForServerChanges() { notice = why; return }
        let directory = remote.path, taken = Set(remote.rows.map(\.name)).subtracting([name]), session = session
        namePrompt = NamePrompt(
            title: "Rename “\(name)”", message: "In \(directory) on \(serverName)", initial: name, action: "Rename",
            problem: { new in new == name ? "That is the current name" : Self.nameProblem(new, taken: taken) },
            command: { FileOperationCommands.command(for: .rename(in: directory, from: name, to: $0)) },
            run: { [self] new in runServerChange(.rename(in: directory, from: name, to: new), session: session) })
    }

    func deleteOnServer(_ names: Set<String>) {
        notice = nil
        if let why = blockedReasonForServerChanges() { notice = why; return }
        let directory = remote.path, session = session
        let rows = remote.rows.filter { names.contains($0.name) }.sorted { $0.name < $1.name }
        guard !rows.isEmpty else { return }
        // A link to a folder is deleted as a link, never followed.
        let ops = rows.map { FileOperation.delete(in: directory, name: $0.name, isFolder: $0.isDirectory && !$0.isLink) }
        var problems: [String] = []
        var commands: [String] = []
        for (row, op) in zip(rows, ops) {
            if let command = FileOperationCommands.command(for: op) { commands.append(command) }
            else if case .delete(_, _, true) = op { problems.append(FileOperationCommands.deleteProblem(folder: RemotePath.join(directory, row.name)) ?? "“\(row.name)” can't be deleted from here.") }
            else { problems.append("“\(row.name)” can't be deleted from here.") }
        }
        deletePrompt = DeletePrompt(
            directory: directory, items: zip(rows, ops).map { row, op in (row.name, { if case .delete(_, _, let f) = op { f } else { false } }()) },
            commands: commands, problems: problems,
            run: { [self] in
                Task {
                    for op in ops {
                        guard await perform(op, session: session) else { break }
                    }
                    remote.reload()
                }
            })
    }

    private func runServerChange(_ op: FileOperation, session: FilesSession) {
        Task {
            _ = await perform(op, session: session)
            remote.reload()
        }
    }

    /// Runs one confirmed change; says why on failure.
    private func perform(_ op: FileOperation, session: FilesSession) async -> Bool {
        do {
            guard let intent = session.intent(for: op) else { notice = "That change can't be made safely from here."; return false }
            try await session.perform(op, confirmation: try session.confirm(intent))
            return true
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return false
        }
    }

    nonisolated static func nameProblem(_ name: String, taken: Set<String>) -> String? {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Enter a name" }
        if !FileTransferCommands.validName(t) { return "That name has a character that can't be used (a slash, or a line break)" }
        if taken.contains(t) { return "That name is already taken" }
        return nil
    }

    // Mac side: plain file operations, deletes go to the Trash.

    func newLocalFolder() {
        let directory = URL(fileURLWithPath: local.path), taken = Set(local.rows.map(\.name))
        namePrompt = NamePrompt(
            title: "New folder on this Mac", message: "In \(local.path)", initial: "", action: "Create",
            problem: { Self.nameProblem($0, taken: taken) }, command: { _ in nil },
            run: { [self] name in
                do { try FileManager.default.createDirectory(at: directory.appendingPathComponent(name.trimmingCharacters(in: .whitespaces)), withIntermediateDirectories: false) }
                catch { notice = error.localizedDescription }
                local.reload()
            })
    }

    func renameLocal(_ name: String) {
        let directory = URL(fileURLWithPath: local.path), taken = Set(local.rows.map(\.name)).subtracting([name])
        namePrompt = NamePrompt(
            title: "Rename “\(name)”", message: "In \(local.path)", initial: name, action: "Rename",
            problem: { new in new == name ? "That is the current name" : Self.nameProblem(new, taken: taken) }, command: { _ in nil },
            run: { [self] new in
                do { try FileManager.default.moveItem(at: directory.appendingPathComponent(name), to: directory.appendingPathComponent(new.trimmingCharacters(in: .whitespaces))) }
                catch { notice = error.localizedDescription }
                local.reload()
            })
    }

    func trashLocal(_ names: Set<String>) {
        let directory = URL(fileURLWithPath: local.path)
        for name in names where name != ".." {
            do { try FileManager.default.trashItem(at: directory.appendingPathComponent(name), resultingItemURL: nil) }
            catch { notice = error.localizedDescription }
        }
        local.reload()
    }

    func revealLocal(_ names: Set<String>) {
        let directory = URL(fileURLWithPath: local.path)
        let urls = names.filter { $0 != ".." }.map { directory.appendingPathComponent($0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [directory] : urls)
    }

    func copyPath(of names: Set<String>, in pane: FilePane) {
        let paths = names.filter { $0 != ".." }.sorted().map { RemotePath.join(pane.path, $0) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((paths.isEmpty ? [pane.path] : paths).joined(separator: "\n"), forType: .string)
    }

    // MARK: drag and drop

    /// The type a server row carries inside this app, so dropping it on the Mac pane uses the normal download queue
    /// (with progress) instead of the system's file-promise route.
    static let remoteItemType = "com.bgallagher.rackoon.remote-item"

    private struct RemoteItemPayload: Codable { let directory: String; let name: String }

    /// What dragging a row of the server pane carries: our own payload (for the Mac pane), plus a lazy file that is only
    /// downloaded if something else (Finder, another app) asks for it.
    func dragProvider(for row: FileRow) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = row.name
        // Rows of one drag are made together; an older set belongs to an earlier drag.
        if Date().timeIntervalSince(liveRemoteDragAt) > 2 { liveRemoteDrag = [] }
        liveRemoteDragAt = Date()
        liveRemoteDrag.insert(row.name)
        let directory = remote.path
        if let data = try? JSONEncoder().encode(RemoteItemPayload(directory: directory, name: row.name)) {
            provider.registerDataRepresentation(forTypeIdentifier: Self.remoteItemType, visibility: .ownProcess) { done in done(data, nil); return nil }
        }
        let type = row.isDirectory ? UTType.folder : (UTType(filenameExtension: (row.name as NSString).pathExtension) ?? .data)
        let session = session, name = row.name, isDirectory = row.isDirectory
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            let progress = Progress(totalUnitCount: -1)
            let task = Task {
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-drag-\(UUID().uuidString)")
                do {
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    try await session.download(name: name, isDirectory: isDirectory, from: directory, toLocalDirectory: scratch,
                                                as: name, replacing: false, progress: { _ in })
                    done(scratch.appendingPathComponent(name, isDirectory: isDirectory), false, nil)
                } catch {
                    done(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    /// What dragging a row of the Mac pane carries: the file itself, so Finder and the server pane both understand it.
    func dragProvider(forLocal row: FileRow) -> NSItemProvider? {
        liveRemoteDrag = []
        if Date().timeIntervalSince(liveLocalDragAt) > 2 { liveLocalDrag = [] }
        liveLocalDragAt = Date()
        liveLocalDrag.insert(row.name)
        // As a file URL (what the server pane's drop reads, and what Finder accepts).
        let url = URL(fileURLWithPath: local.path).appendingPathComponent(row.name, isDirectory: row.isDirectory)
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = row.name
        return provider
    }

    /// Names of server rows being dragged right now. A drop on the Mac pane recognises its own window's drag by this,
    /// in case the system doesn't hand our custom type through.
    @ObservationIgnored private var liveRemoteDrag: Set<String> = []
    @ObservationIgnored private var liveRemoteDragAt = Date.distantPast
    /// The same for rows of the Mac pane: inside one app the system hands a drop only the file type, not the file's URL.
    @ObservationIgnored private var liveLocalDrag: Set<String> = []
    @ObservationIgnored private var liveLocalDragAt = Date.distantPast

    /// Dropped on the server pane: files from Finder (or the Mac pane) go up.
    func dropOnRemote(_ providers: [NSItemProvider]) -> Bool {
        let carriers = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        if carriers.isEmpty {
            // A drag of this window's own Mac pane rows.
            guard Date().timeIntervalSince(liveLocalDragAt) < 120, !liveLocalDrag.isEmpty else { return false }
            let chosen = local.selection.intersection(liveLocalDrag)
            let names = chosen.isEmpty ? liveLocalDrag : chosen
            liveLocalDrag = []
            Task { upload(names.filter { name in local.rows.contains { $0.name == name } }) }
            return true
        }
        Task {
            var urls: [URL] = []
            for provider in carriers {
                if let url = await Self.loadURL(provider) { urls.append(url) }
            }
            upload(urls: urls.filter { $0.isFileURL })
        }
        return true
    }

    /// Dropped on the Mac pane: server rows from this window come down into the Mac pane's folder.
    func dropOnLocal(_ providers: [NSItemProvider]) -> Bool {
        // Our own payload when it came through, else the name the drag was started with.
        // The system strips our payload and the name from a drag that stays inside the app (only the file type is left), so
        // a drop that carries no URL and follows a drag of server rows is that drag.
        let recent = Date().timeIntervalSince(liveRemoteDragAt) < 120 && !liveRemoteDrag.isEmpty
        let carriers = providers.filter {
            $0.hasItemConformingToTypeIdentifier(Self.remoteItemType) || ($0.suggestedName.map(liveRemoteDrag.contains) ?? false)
                || (recent && !$0.canLoadObject(ofClass: URL.self))
        }
        guard !carriers.isEmpty else { return false }
        // Rows touched just before the drag may be in the set; the dragged ones are the selected ones.
        let selected = remote.selection.intersection(liveRemoteDrag)
        let fallback = selected.isEmpty ? liveRemoteDrag : selected
        Task {
            var names: Set<String> = []
            for provider in carriers {
                if provider.hasItemConformingToTypeIdentifier(Self.remoteItemType),
                   let data = await Self.loadData(provider, type: Self.remoteItemType),
                   let item = try? JSONDecoder().decode(RemoteItemPayload.self, from: data) {
                    if item.directory == remote.path { names.insert(item.name) }
                } else if let name = provider.suggestedName, liveRemoteDrag.contains(name) {
                    names.insert(name)
                } else {
                    names.formUnion(fallback)
                }
            }
            names = names.filter { name in remote.rows.contains { $0.name == name } }
            if !names.isEmpty { download(names) }
        }
        return true
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
        }
    }

    private static func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { c in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in c.resume(returning: data) }
        }
    }

    // MARK: queue

    /// Transfers run one at a time; the destination pane reloads when its copy ends.
    private func add(_ transfer: FileTransfer, reload pane: FilePane, folder: String) {
        transfers.append(transfer)
        let previous = worker
        worker = Task { [weak self] in
            await previous?.value
            guard let self, transfer.state == .waiting else { return }
            transfer.set(.running)
            let job = Task { @MainActor in
                do {
                    try await transfer.work(transfer)
                    transfer.set(.done)
                } catch is CancellationError {
                    transfer.set(.cancelled)
                } catch {
                    transfer.set(Task.isCancelled ? .cancelled : .failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                }
            }
            transfer.task = job
            await job.value
            if pane.path == folder { pane.reload() }
        }
    }

    // MARK: helpers

    /// "report.pdf" -> "report copy.pdf" -> "report copy 2.pdf", skipping names in `taken`.
    nonisolated static func copyName(_ name: String, avoiding taken: Set<String>) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        // A leading dot is part of the name, not an extension (".env" -> ".env copy").
        let hasExt = !ext.isEmpty && !(ns.lastPathComponent.hasPrefix(".") && ns.deletingPathExtension == "")
        let stem = hasExt ? ns.deletingPathExtension : name
        for n in 1... {
            let candidate = (n == 1 ? "\(stem) copy" : "\(stem) copy \(n)") + (hasExt ? ".\(ext)" : "")
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    // MARK: local listing

    private static func listLocal(_ path: String) async throws -> FolderContents {
        try await Task.detached {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
            } catch {
                throw LocalFilesError.unreadable(path, (error as NSError).localizedFailureReason ?? error.localizedDescription)
            }
            let rows = urls.map { u -> FileRow in
                let values = try? u.resourceValues(forKeys: Set(keys))
                let isLink = values?.isSymbolicLink ?? false
                // A link to a folder opens like a folder.
                let isDirectory = isLink ? ((try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                                         : (values?.isDirectory ?? false)
                let attributes = try? FileManager.default.attributesOfItem(atPath: u.path)
                let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
                return FileRow(name: u.lastPathComponent, isDirectory: isDirectory, isLink: isLink,
                               size: isDirectory ? nil : Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate,
                               permissions: permissionString(mode: mode, isDirectory: isDirectory, isLink: isLink),
                               kindLabel: FileRow.kind(name: u.lastPathComponent, isDirectory: isDirectory, isLink: isLink))
            }
            return FolderContents(path: url.standardizedFileURL.path, rows: rows, truncated: false)
        }.value
    }

    nonisolated static func permissionString(mode: Int, isDirectory: Bool, isLink: Bool) -> String {
        let bits = "rwxrwxrwx"
        var out = isLink ? "l" : isDirectory ? "d" : "-"
        for (i, c) in bits.enumerated() { out.append(mode & (1 << (8 - i)) != 0 ? c : "-") }
        return out
    }
}

enum LocalFilesError: LocalizedError {
    case unreadable(String, String)
    var errorDescription: String? {
        switch self {
        case .unreadable(let path, let why): "Couldn't open \(path): \(why)"
        }
    }
}

/// The transfer engine for a server: real ssh, or a pretend one in demo mode.
func makeTransfers(for server: Server) -> FileTransferring {
    Demo.isOn ? DemoTransfers() : OpenSSHTransport(server: server)
}

/// Demo mode: copies "work" but nothing is sent anywhere and nothing real is written except small placeholder files.
struct DemoTransfers: FileTransferring {
    func upload(_ source: LocalSource, remoteCommand: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(120))
            progress(Int64(step) * 400_000)
        }
    }

    func download(remoteCommand: String, to sink: LocalSink, progress: @escaping @Sendable (Int64) -> Void) async throws {
        for step in 1...6 {
            try await Task.sleep(for: .milliseconds(120))
            progress(Int64(step) * 40_000)
        }
        switch sink {
        case .file(let url): try Data("Demo file: nothing was downloaded.\n".utf8).write(to: url)
        case .folder(let into):
            // The command ends with the quoted folder name: tar -C '<dir>' -cf - -- '<name>'
            let name = remoteCommand.split(separator: "'").last.map(String.init) ?? "folder"
            let dir = into.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("Demo file.\n".utf8).write(to: dir.appendingPathComponent("README.txt"))
        }
    }
}
