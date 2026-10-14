import Foundation
import RackoonCore
import RackoonSSHSystem

/// One bookmark found on a running container, with where it lives.
struct BookmarkItem: Identifiable {
    let stack: DockerStack
    let container: DockerContainer
    let bookmark: Bookmark
    var id: String { container.id }
    var service: String { container.service ?? container.name }
    /// What the list shows: the bookmark's name, or the service's.
    var title: String { bookmark.title(fallback: service) }
}

extension DockerModel {
    /// Stacks a bookmark can be added to: compose stacks with at least one container and compose files we can edit.
    var bookmarkableStacks: [DockerStack] {
        stacks.filter { !$0.isStandalone && !$0.containers.isEmpty && StackFiles.editable(for: $0) != nil }
    }

    var bookmarkItems: [BookmarkItem] {
        stacks.flatMap { stack in
            stack.containers.compactMap { c in c.bookmark.map { BookmarkItem(stack: stack, container: c, bookmark: $0) } }
        }
    }

    var bookmarkGroups: [String] {
        Array(Set(bookmarkItems.compactMap(\.bookmark.group))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// State of the bookmark modal: which stack and service, the fields, and writing the Homepage labels into compose.yaml.
/// Nothing is written until the user confirms the diff, and the server checks the file before it is saved.
@MainActor @Observable
final class BookmarkModel: Identifiable {
    nonisolated let id = UUID()
    let choices: [DockerStack]
    let groups: [String]
    /// The stack was chosen outside the modal (a card, or Edit), so it can't be changed here.
    let stackLocked: Bool
    private(set) var stack: DockerStack?
    private(set) var service = ""
    private(set) var existing: Bookmark?
    var url = ""
    var name = ""
    var group = ""
    var icon = ""
    var details = ""
    private(set) var busy = false
    var notice: String?
    var pending: PendingAction?

    let serverName: String
    @ObservationIgnored private let server: Server
    @ObservationIgnored private var blockedReason: (DockerStack) -> String? = { _ in nil }
    @ObservationIgnored private var finished: (DockerStack, Bool) -> Void = { _, _ in }

    /// No side effects here: SwiftUI may construct this more than once.
    init(server: Server, choices: [DockerStack], groups: [String], stack: DockerStack?, service: String? = nil) {
        self.server = server
        serverName = server.name
        self.choices = choices
        self.groups = groups
        stackLocked = stack != nil
        if let stack { choose(stack, service: service) }
    }

    /// Hands the modal what the screen showing it provides: why an action is blocked, and what happens when it is saved
    /// (`true` when the stack should be updated so the label shows up).
    func attach(blockedReason: @escaping (DockerStack) -> String?, finished: @escaping (DockerStack, Bool) -> Void) {
        self.blockedReason = blockedReason
        self.finished = finished
    }

    // MARK: choosing

    var services: [String] {
        Array(Set(stack?.containers.compactMap(\.service) ?? [])).sorted()
    }

    func choose(_ new: DockerStack, service wanted: String? = nil) {
        stack = new
        notice = nil
        let names = services
        choose(service: wanted.flatMap { names.contains($0) ? $0 : nil } ?? names.first(where: { name in
            new.containers.first { $0.service == name }?.bookmark != nil
        }) ?? names.first ?? "")
    }

    func choose(service new: String) {
        service = new
        notice = nil
        existing = stack?.containers.first { $0.service == new }?.bookmark
        if let b = existing {
            url = b.href; name = b.name ?? ""; group = b.group ?? ""; icon = b.icon ?? ""; details = b.description ?? ""
        } else {
            url = ""; name = ""; group = ""; icon = ""; details = ""
        }
    }

    // MARK: fields

    /// A bare address like `app.example.com` is read as https.
    var normalizedURL: String {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.contains("://") ? t : "https://" + t
    }

    var urlProblem: String? {
        url.trimmingCharacters(in: .whitespaces).isEmpty || Bookmark.isValidURL(normalizedURL)
            ? nil : "Enter a web address such as https://app.example.com"
    }

    private var bookmark: Bookmark? {
        Bookmark.isValidURL(normalizedURL)
            ? Bookmark(href: normalizedURL, name: name, group: group, icon: icon, description: details) : nil
    }

    var saveBlockedReason: String? {
        if SafetyStore.shared.readOnly { return "Read-only mode is on" }
        if busy { return "Working…" }
        guard let stack else { return "Choose a stack" }
        if service.isEmpty { return "This stack has no containers to bookmark" }
        if url.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a web address" }
        if bookmark == nil { return urlProblem }
        return blockedReason(stack)
    }

    // MARK: writing

    func requestSave(apply: Bool) {
        guard saveBlockedReason == nil, let bookmark else { return }
        prepare(changes: bookmark.labelChanges, apply: apply, removing: false)
    }

    func requestRemoval(apply: Bool = true) {
        guard !busy, stack != nil, !service.isEmpty else { return }
        prepare(changes: Bookmark.removalChanges, apply: apply, removing: true)
    }

    /// Reads the compose file that defines the service, edits its labels, and asks the user to confirm the diff.
    private func prepare(changes: [(key: String, value: String?)], apply: Bool, removing: Bool) {
        guard let stack, let files = StackFiles.editable(for: stack) else { return }
        let service = service
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                let session = StackFileSession(transport: dockerTransport(for: server), policy: SafetyStore.shared.policy, stack: stack)
                // The first compose file that defines the service (an override file may be the one that does).
                var found: (file: EditableFile, remote: RemoteFile, text: String)?
                var unreadable: [String] = []
                for file in files where !file.isEnv {
                    switch try await session.read(file) {
                    case .file(let remote):
                        guard ComposeLabels.definesService(service, in: remote.content) else { continue }
                        found = (file, remote, try ComposeLabels.setting(changes, onService: service, in: remote.content))
                    case .missing: unreadable.append("\(file.fileName) is missing on \(serverName)")
                    case .tooLarge: unreadable.append("\(file.fileName) is too large to edit here")
                    }
                    if found != nil { break }
                }
                guard let found else {
                    // Say why when a file could not be read, instead of claiming the service doesn't exist.
                    notice = unreadable.isEmpty ? "No compose file of \(stack.name) defines a service called \(service)."
                                                : "Couldn't read the stack's compose file: " + unreadable.joined(separator: "; ") + "."
                    return
                }
                guard found.text != found.remote.content else {
                    notice = removing ? "\(service) has no bookmark labels to remove." : "Nothing would change in \(found.file.fileName)."
                    return
                }
                let edit = FileEdit(file: found.file, original: found.remote.content, originalSHA: found.remote.sha256, content: found.text)
                guard let intent = session.intent(for: edit) else { notice = "That change can't be saved."; return }
                let up = apply ? (ComposeAction.up.command(for: stack) ?? "") : ""
                let what = removing ? "Remove the bookmark from \(service)" : "Bookmark \(service)"
                pending = PendingAction(
                    title: apply ? "\(what) and update \(stack.name)?" : "\(what)?",
                    message: "The labels are written into \(found.file.fileName); the server checks the file first, and the old one is kept as \(found.file.fileName).rackoon.bak."
                        + (apply ? " Then the stack is updated, which recreates \(service) (a few seconds of downtime) so the change shows up." : " It takes effect the next time the stack is updated."),
                    serverName: serverName, command: up, destructive: false, preview: intent.preview,
                    run: { [weak self] in self?.perform(edit, session: session, stack: stack, apply: apply) })
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func perform(_ edit: FileEdit, session: StackFileSession, stack: DockerStack, apply: Bool) {
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                switch try await session.save(edit, confirmation: try session.confirm(edit)) {
                case .saved: finished(stack, apply)
                case .changedOnServer:
                    notice = "\(edit.file.fileName) changed on \(serverName) after you opened this, so nothing was saved. Close this and try again."
                case .invalid(let issues):
                    notice = "\(serverName) refused the file: " + (issues.first.map(EditorChecks.describe) ?? "it did not pass the compose check")
                }
            } catch { notice = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }
}
