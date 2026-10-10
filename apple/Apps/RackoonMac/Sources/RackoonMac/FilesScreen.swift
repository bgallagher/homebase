import RackoonCore
import SwiftUI
import UniformTypeIdentifiers

/// Files: this Mac on the left, the server on the right. Browsing only for now (open folders, go back and forward,
/// filter, sort); copying between the panes comes next.
struct FilesScreen: View {
    let server: Server
    /// Opens a terminal tab on the server in a folder.
    let openTerminal: (String) -> Void
    private let model: FilesModel

    init(server: Server, workspace: DockerWorkspace, openTerminal: @escaping (String) -> Void) {
        self.server = server
        self.openTerminal = openTerminal
        model = workspace.filesModel(for: server)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Files").font(.system(size: 26, weight: .bold)).tracking(-0.4)
            if let notice = model.notice { ErrorBanner(message: notice) }
            HStack(spacing: 14) {
                FilePaneView(pane: model.local, title: "This Mac", symbol: "laptopcomputer",
                             copy: PaneCopy(label: "Upload", symbol: "arrow.up", help: "Copy the selection to \(server.name)",
                                            blocked: { model.canUpload($0) }, run: model.upload),
                             drag: { model.dragProvider(forLocal: $0) },
                             dropTypes: [.item], drop: model.dropOnLocal,
                             menu: PaneMenu(newFolder: model.newLocalFolder, rename: model.renameLocal,
                                            delete: model.trashLocal, deleteLabel: "Move to Trash", copyPath: { model.copyPath(of: $0, in: model.local) },
                                            revealLabel: "Reveal in Finder", reveal: model.revealLocal, openTerminal: nil, blocked: nil))
                FilePaneView(pane: model.remote, title: server.name, symbol: "server.rack",
                             copy: PaneCopy(label: "Download", symbol: "arrow.down", help: "Copy the selection to this Mac",
                                            blocked: { _ in nil }, run: model.download),
                             drag: { model.dragProvider(for: $0) },
                             dropTypes: [.fileURL], drop: model.dropOnRemote,
                             menu: PaneMenu(newFolder: model.newServerFolder, rename: model.renameOnServer,
                                            delete: model.deleteOnServer, deleteLabel: "Delete…", copyPath: { model.copyPath(of: $0, in: model.remote) },
                                            revealLabel: nil, reveal: nil, openTerminal: { openTerminal(model.remote.path) },
                                            blocked: model.blockedReasonForServerChanges))
            }
            if !model.transfers.isEmpty { TransfersPanel(model: model) }
        }
        .padding(.horizontal, 32).padding(.top, Theme.pageTop).padding(.bottom, 24)
        .foregroundStyle(Theme.textPrimary)
        .onAppear { model.start() }
        .focusedSceneValue(\.screenRefresh, { model.local.reload(); model.remote.reload() })
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
        .sheet(item: Binding(get: { model.conflict }, set: { model.conflict = $0 })) { conflict in
            ConflictSheet(conflict: conflict, serverName: server.name) { model.conflict = nil }
        }
        .sheet(item: Binding(get: { model.namePrompt }, set: { model.namePrompt = $0 })) { prompt in
            NameSheet(prompt: prompt) { model.namePrompt = nil }
        }
        .sheet(item: Binding(get: { model.deletePrompt }, set: { model.deletePrompt = $0 })) { prompt in
            DeleteFilesSheet(prompt: prompt, serverName: server.name) { model.deletePrompt = nil }
        }
    }
}

/// The change actions of one pane (context menu and Actions menu).
struct PaneMenu {
    let newFolder: () -> Void
    let rename: (String) -> Void
    let delete: (Set<String>) -> Void
    let deleteLabel: String
    let copyPath: (Set<String>) -> Void
    let revealLabel: String?
    let reveal: ((Set<String>) -> Void)?
    let openTerminal: (() -> Void)?
    /// Why changes are blocked (Read-only), or nil.
    let blocked: (() -> String?)?
}

/// Asks for a name (new folder, rename) and shows the command that will run.
private struct NameSheet: View {
    let prompt: FilesModel.NamePrompt
    let close: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(prompt: FilesModel.NamePrompt, close: @escaping () -> Void) {
        self.prompt = prompt
        self.close = close
        _text = State(initialValue: prompt.initial)
    }

    var body: some View {
        let problem = prompt.problem(text)
        let command = problem == nil ? prompt.command(text.trimmingCharacters(in: .whitespaces)) : nil
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(.system(size: 16, weight: .semibold))
            if let m = prompt.message { Text(m).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit(go)
            if let problem, !text.isEmpty { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.warn) }
            if let command {
                Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).handCursor()
                Button(prompt.action, action: go).keyboardShortcut(.defaultAction).disabled(problem != nil).handCursor()
            }
        }
        .padding(22).frame(width: 440)
        .onAppear { focused = true }
    }

    private func go() {
        guard prompt.problem(text) == nil else { return }
        let name = text.trimmingCharacters(in: .whitespaces)
        close()
        prompt.run(name)
    }
}

/// Confirms deleting on the server: what goes, the exact commands, and a typed word when a folder is included.
private struct DeleteFilesSheet: View {
    let prompt: FilesModel.DeletePrompt
    let serverName: String
    let close: () -> Void
    @State private var typed = ""

    var body: some View {
        let blocked = !prompt.problems.isEmpty
        let needsWord = prompt.hasFolder
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(prompt.items.count == 1 ? "“\(prompt.items[0].name)”" : "\(prompt.items.count) items") on \(serverName)?")
                .font(.system(size: 16, weight: .semibold))
            Text("In \(prompt.directory). This can't be undone.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(prompt.items, id: \.name) { item in
                    Label(item.name + (item.isFolder ? "  (and everything inside)" : ""), systemImage: item.isFolder ? "folder" : "doc")
                        .font(.system(size: 12)).lineLimit(1)
                }
            }
            ForEach(prompt.problems, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            if !blocked {
                ScrollView {
                    Text(prompt.commands.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textMuted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
                if needsWord {
                    Text("Type delete to confirm").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    TextField("delete", text: $typed).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).handCursor()
                Button("Delete") { close(); prompt.run() }
                    .keyboardShortcut(.defaultAction).tint(Theme.danger)
                    .disabled(blocked || (needsWord && typed.lowercased() != "delete")).handCursor()
            }
        }
        .padding(22).frame(width: 480)
    }
}

/// What a pane's Upload / Download button does with the selection.
struct PaneCopy {
    let label: String
    let symbol: String
    let help: String
    /// A reason the button is disabled, or nil.
    let blocked: (Set<String>) -> String?
    let run: (Set<String>) -> Void
}

/// Some names already exist at the destination: replace, keep both, or skip them.
private struct ConflictSheet: View {
    let conflict: FileConflict
    let serverName: String
    let close: () -> Void

    var body: some View {
        let up = conflict.direction == .upload
        VStack(alignment: .leading, spacing: 14) {
            Text(conflict.names.count == 1 ? "“\(conflict.names[0])” already exists" : "\(conflict.names.count) items already exist")
                .font(.system(size: 16, weight: .semibold))
            Text("\(up ? "On \(serverName)" : "On this Mac"), in the destination folder. Replacing a folder merges the new files into it.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if conflict.names.count > 1 {
                Text(conflict.names.prefix(6).joined(separator: ", ") + (conflict.names.count > 6 ? " and \(conflict.names.count - 6) more" : ""))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).handCursor()
                Spacer()
                Button("Skip") { choose(.skipExisting) }.handCursor()
                Button("Keep Both") { choose(.keepBoth) }.handCursor()
                Button("Replace") { choose(.replace) }.keyboardShortcut(.defaultAction).handCursor()
            }
        }
        .padding(22).frame(width: 440)
    }

    private func choose(_ r: FileConflict.Resolution) { close(); conflict.resolve(r) }
}

/// The transfer list under the panes: progress, Cancel, and Clear for finished ones.
private struct TransfersPanel: View {
    let model: FilesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textMuted)
                Spacer()
                if model.hasFinished { Button("Clear Finished") { model.clearFinished() }.buttonStyle(.pointer).font(.system(size: 12)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.transfers) { t in
                        TransferRow(transfer: t)
                        if t.id != model.transfers.last?.id { Divider().overlay(Theme.border) }
                    }
                }
            }
            .frame(maxHeight: 130)
        }
        .card()
    }
}

private struct TransferRow: View {
    let transfer: FileTransfer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(color).lineLimit(2)
            }
            Spacer()
            if case .running = transfer.state {
                if let f = transfer.fraction { ProgressView(value: f).frame(width: 140) } else { ProgressView().controlSize(.small) }
            }
            if !transfer.isFinished {
                Button("Cancel") { transfer.cancel() }.buttonStyle(.pointer).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var color: Color {
        if case .failed = transfer.state { Theme.danger } else { Theme.textMuted }
    }

    private var status: String {
        let to = transfer.direction == .upload ? "to server: " : "to this Mac: "
        switch transfer.state {
        case .waiting: return "Waiting"
        case .running:
            let done = Format.bytes(transfer.bytes)
            return transfer.total.map { "\(done) of \(Format.bytes($0))" } ?? done
        case .done: return "Done " + to + transfer.destination
        case .cancelled: return "Cancelled"
        case .failed(let why): return "Failed: " + why
        }
    }
}

/// One pane: header (name, filter), breadcrumb with back and forward, and the file table.
struct FilePaneView: View {
    @Bindable var pane: FilePane
    let title: String
    let symbol: String
    let copy: PaneCopy
    /// What dragging one of this pane's rows carries.
    let drag: (FileRow) -> NSItemProvider?
    /// What can be dropped on this pane, and what happens then.
    let dropTypes: [UTType]
    let drop: ([NSItemProvider]) -> Bool
    let menu: PaneMenu
    @State private var dropTargeted = false
    @State private var sortOrder = [KeyPathComparator(\FileRow.name)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            breadcrumb
            Divider().overlay(Theme.border)
            if let error = pane.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(Theme.border)
            }
            table
            if pane.truncated {
                Divider().overlay(Theme.border)
                Text("Only the first \(RemoteFiles.maxEntries) items are shown.")
                    .font(.system(size: 11)).foregroundStyle(Theme.warn).padding(8)
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.accent, lineWidth: 2).opacity(dropTargeted ? 1 : 0))
        .onDrop(of: dropTypes, delegate: LoggingDrop(types: dropTypes, targeted: $dropTargeted, title: title, perform: drop))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if pane.loading { ProgressView().controlSize(.small) }
            Spacer()
            let blocked = copy.blocked(pane.selection)
            Button { copy.run(pane.selection) } label: { Label(copy.label, systemImage: copy.symbol) }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(blocked != nil || pane.selection.subtracting([".."]).isEmpty)
                .help(blocked ?? copy.help)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Filter", text: $pane.filter).textFieldStyle(.plain).frame(width: 110)
            }
            Menu {
                let chosen = pane.selection.subtracting([".."])
                let blocked = menu.blocked?()
                Button("New Folder…", action: menu.newFolder).disabled(blocked != nil)
                Button("Rename…") { if let name = chosen.first { menu.rename(name) } }.disabled(chosen.count != 1 || blocked != nil)
                Button(menu.deleteLabel) { menu.delete(chosen) }.disabled(chosen.isEmpty || blocked != nil)
                Divider()
                Button("Copy Path") { menu.copyPath(chosen) }
                if let reveal = menu.reveal, let label = menu.revealLabel { Button(label) { reveal(chosen) } }
                if let terminal = menu.openTerminal { Button("Open Terminal Here", action: terminal) }
                Divider()
                Toggle("Show Hidden Files", isOn: $pane.showHidden)
                Button("Reload") { pane.reload() }
                Button("Copy Folder Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pane.path, forType: .string)
                }
            } label: { Text("Actions") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            navButton("chevron.left", enabled: pane.canGoBack, help: "Back") { pane.goBack() }
            navButton("chevron.right", enabled: pane.canGoForward, help: "Forward") { pane.goForward() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(RemotePath.crumbs(pane.path).enumerated()), id: \.offset) { index, crumb in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textMuted) }
                        Button { pane.open(crumb.path) } label: {
                            Text(crumb.name).font(.system(size: 12)).lineLimit(1)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                        }
                        .buttonStyle(.pointer)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func navButton(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.pointer)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }

    private var table: some View {
        let rows = pane.visibleRows
        return Table(of: FileRow.self, selection: $pane.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 7) {
                    Image(systemName: row.isDirectory ? "folder.fill" : (row.isLink ? "link" : "doc"))
                        .foregroundStyle(row.isDirectory ? Theme.accent : Theme.textMuted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name).lineLimit(1)
                        Text(row.permissions).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
            TableColumn("Date Modified", value: \.modifiedSort) { row in
                Text(row.modified.map { $0.formatted(date: .numeric, time: .shortened) } ?? "--")
                    .foregroundStyle(Theme.textSecondary)
            }.width(min: 110, ideal: 130)
            TableColumn("Size", value: \.sizeSort) { row in
                Text(row.size.map { Format.bytes($0) } ?? "--").foregroundStyle(Theme.textSecondary)
            }.width(min: 60, ideal: 70)
            TableColumn("Kind", value: \.kindLabel) { row in
                Text(row.kindLabel).foregroundStyle(Theme.textSecondary)
            }.width(min: 50, ideal: 60)
        } rows: {
            if let parent = pane.parentPath {
                // The ".." row: opens the parent folder.
                TableRow(FileRow(name: "..", isDirectory: true, isLink: false, size: nil, modified: nil, permissions: "", kindLabel: "folder"))
                    .contextMenu { Button("Open Parent Folder") { pane.open(parent) } }
            }
            ForEach(rows) { row in TableRow(row).itemProvider { drag(row) } }
        }
        .contextMenu(forSelectionType: String.self) { names in
            let chosen = names.subtracting([".."])
            let blocked = menu.blocked?()
            if !chosen.isEmpty {
                if chosen.count == 1, let name = chosen.first {
                    Button("Rename…") { menu.rename(name) }.disabled(blocked != nil)
                }
                Button(menu.deleteLabel) { menu.delete(chosen) }.disabled(blocked != nil)
                Divider()
                Button("Copy Path") { menu.copyPath(chosen) }
                if let reveal = menu.reveal, let label = menu.revealLabel { Button(label) { reveal(chosen) } }
            }
            Button("New Folder…", action: menu.newFolder).disabled(blocked != nil)
            if let terminal = menu.openTerminal { Button("Open Terminal Here", action: terminal) }
        } primaryAction: { names in
            guard let name = names.first else { return }
            activate(name)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            pane.sortKey = first.keyPath == \FileRow.modifiedSort ? .modified : first.keyPath == \FileRow.sizeSort ? .size
                : first.keyPath == \FileRow.kindLabel ? .kind : .name
            pane.ascending = first.order == .forward
        }
    }

    private func activate(_ name: String) {
        if name == "..", let parent = pane.parentPath { pane.open(parent); return }
        guard let row = pane.rows.first(where: { $0.name == name }), row.isDirectory else { return }
        pane.open(RemotePath.join(pane.path, row.name))
    }
}

/// A drop target that also says what it was offered (for finding out why a drag is refused).
private struct LoggingDrop: DropDelegate {
    let types: [UTType]
    @Binding var targeted: Bool
    let title: String
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: types)
    }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return perform(info.itemProviders(for: types))
    }
}
