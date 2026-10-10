import Foundation
import Observation
import RackoonCore

/// One row in a file pane, whichever side it came from.
struct FileRow: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let isLink: Bool
    /// Folders have no size shown.
    let size: Int64?
    let modified: Date?
    let permissions: String
    let kindLabel: String

    /// Non-optional values for the table's sortable columns.
    var modifiedSort: Date { modified ?? .distantPast }
    var sizeSort: Int64 { size ?? -1 }
}

/// What a pane's loader gives back for a folder.
struct FolderContents {
    let path: String
    let rows: [FileRow]
    let truncated: Bool
}

enum FileSortKey { case name, modified, size, kind }

/// One side of the Files screen: where it is, what is in it, history, filter and sort. Local and remote panes differ
/// only in their `loader`.
@MainActor @Observable
final class FilePane {
    private(set) var path: String
    private(set) var rows: [FileRow] = []
    private(set) var loading = false
    private(set) var truncated = false
    var error: String?
    var filter = ""
    var sortKey: FileSortKey = .name
    var ascending = true
    var showHidden: Bool
    var selection: Set<String> = []
    private(set) var back: [String] = []
    private(set) var forward: [String] = []

    @ObservationIgnored private let loader: (String) async throws -> FolderContents
    @ObservationIgnored private var generation = 0

    init(path: String, showHidden: Bool, loader: @escaping (String) async throws -> FolderContents) {
        self.path = path
        self.showHidden = showHidden
        self.loader = loader
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var parentPath: String? { RemotePath.parent(of: path) }

    /// Rows as shown: hidden files and the filter applied, folders first, then the chosen sort.
    var visibleRows: [FileRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let shown = rows.filter { row in
            (showHidden || !row.name.hasPrefix(".")) && (needle.isEmpty || row.name.localizedCaseInsensitiveContains(needle))
        }
        return shown.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: Bool
            switch sortKey {
            case .name: order = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: order = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .size: order = (a.size ?? -1) < (b.size ?? -1)
            case .kind: order = a.kindLabel == b.kindLabel ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.kindLabel < b.kindLabel
            }
            return ascending ? order : !order
        }
    }

    func sort(by key: FileSortKey) {
        if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = true }
    }

    /// Go to a folder (a click, a breadcrumb, `..`): the old place goes on the back list.
    func open(_ target: String) {
        guard target != path || rows.isEmpty else { return }
        let previous = path
        load(target) { [self] in
            if previous != path { back.append(previous) }
            forward = []
        }
    }

    func goBack() {
        guard let target = back.last else { return }
        let previous = path
        load(target) { [self] in
            back.removeLast()
            forward.append(previous)
        }
    }

    func goForward() {
        guard let target = forward.last else { return }
        let previous = path
        load(target) { [self] in
            forward.removeLast()
            back.append(previous)
        }
    }

    func reload() { load(path) {} }

    /// Loads `target`; on success shows it and runs `committed`, on failure keeps the current folder and says why.
    private func load(_ target: String, committed: @escaping () -> Void) {
        generation += 1
        let mine = generation
        loading = true
        error = nil
        Task {
            do {
                let contents = try await loader(target)
                guard mine == generation else { return }
                path = contents.path
                rows = contents.rows
                truncated = contents.truncated
                selection = []
                committed()
            } catch {
                guard mine == generation else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            if mine == generation { loading = false }
        }
    }
}

extension FileRow {
    init(_ entry: FolderEntry) {
        name = entry.name
        isDirectory = entry.isDirectory
        isLink = entry.kind == .symlink
        size = entry.isDirectory ? nil : entry.size
        modified = entry.modified
        permissions = entry.permissions
        kindLabel = Self.kind(name: entry.name, isDirectory: entry.isDirectory, isLink: entry.kind == .symlink, isOther: entry.kind == .other)
    }

    /// "folder", "alias" (a link), or the extension in lower case ("yaml", "png"), else "file".
    static func kind(name: String, isDirectory: Bool, isLink: Bool, isOther: Bool = false) -> String {
        if isDirectory { return isLink ? "folder link" : "folder" }
        if isLink { return "link" }
        if isOther { return "special" }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") ? "file" : ext
    }
}
