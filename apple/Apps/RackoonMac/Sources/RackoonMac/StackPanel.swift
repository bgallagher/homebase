import RackoonCore
import SwiftUI

enum PanelSelection: Hashable {
    case logs
    case file(EditableFile)
}

/// The framed panel on a stack's detail page: a Logs tab, and one tab per editable file (compose files, then .env).
struct StackPanel: View {
    let stack: DockerStack
    let model: DockerModel
    let editor: StackEditorModel
    let theme: TerminalTheme
    let busy: Set<String>
    let serverName: String
    @Binding var tab: PanelSelection

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            switch tab {
            case .logs: logs
            case .file(let file): FileEditorBody(editor: editor, file: file, theme: theme, serverName: serverName)
            }
        }
        .frame(minHeight: 620)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
        .confirmAction(Binding(get: { editor.pending }, set: { editor.pending = $0 }))
        .onChange(of: tab) { _, new in if case .file(let f) = new { editor.open(f) } }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            TabButton(label: "Logs", dirty: false, selected: tab == .logs) { tab = .logs }
            ForEach(editor.files, id: \.self) { file in
                TabButton(label: file.fileName, dirty: editor.isDirty(file), selected: tab == .file(file)) { tab = .file(file) }
            }
            Spacer()
            if case .file(let file) = tab, editor.isDirty(file) {
                let n = editor.changeCount(file)
                Text("\(n) line\(n == 1 ? "" : "s") changed").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 12).frame(height: 42)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    @ViewBuilder private var logs: some View {
        if let target = model.logTarget, stack.containers.contains(where: { $0.id == target.id }) {
            LogPanel(model: model, container: target, theme: theme, busy: busy.contains(target.id))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.alignleft").font(.system(size: 22)).foregroundStyle(Theme.textMuted)
                Text("Choose Logs on a container to follow its output.").foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: theme.backgroundRGB.nsColor))
        }
    }
}

private struct TabButton: View {
    let label: String
    let dirty: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, design: .monospaced))
                if dirty { Circle().fill(Theme.accent).frame(width: 6, height: 6).help("Unsaved changes") }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.pointer)
    }
}

/// One file's editor: the code view, the checklist from the server, and Revert / Save / Save and redeploy.
private struct FileEditorBody: View {
    let editor: StackEditorModel
    let file: EditableFile
    let theme: TerminalTheme
    let serverName: String

    var body: some View {
        let d = editor.draft(file)
        VStack(spacing: 0) {
            noticeBanner
            if let error = d.loadError {
                VStack(spacing: 10) {
                    Text(error).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                    Button("Try Again") { editor.reload(file) }.buttonStyle(.bordered).handCursor()
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if d.original == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading \(file.fileName) from \(serverName)…") }
                    .foregroundStyle(Theme.textMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if d.original == .missing {
                    Label("\(file.fileName) doesn't exist yet. Saving creates it (readable only by its owner).", systemImage: "doc.badge.plus")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card)
                }
                CodeEditorView(text: Binding(get: { editor.text(file) }, set: { editor.setText(file, $0) }),
                               isEnv: file.isEnv, theme: theme,
                               changedLines: editor.changedLines(file), errorLines: editor.errorLines(file))
                    .id(file)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                checks
                footer
            }
        }
    }

    // MARK: notices

    @ViewBuilder private var noticeBanner: some View {
        switch editor.notice {
        case .saved(let name, let redeployed)?:
            banner(symbol: "checkmark.circle.fill", color: Theme.ok,
                   text: "Saved \(name). The previous version is kept as \(name).rackoon.bak." + (redeployed ? " Updating the stack…" : ""))
        case .changedOnServer(let changed)?:
            banner(symbol: "exclamationmark.triangle.fill", color: Theme.warn,
                   text: "\(changed.fileName) changed on the server after you opened it, so nothing was saved.") {
                Button("Reload from Server") { editor.reload(changed) }.buttonStyle(.bordered).handCursor()
                Button("Keep Editing") { editor.notice = nil }.buttonStyle(.bordered).handCursor()
            }
        case .failed(let message)?:
            banner(symbol: "xmark.octagon.fill", color: Theme.danger, text: message)
        case nil:
            EmptyView()
        }
    }

    private func banner(symbol: String, color: Color, text: String) -> some View {
        banner(symbol: symbol, color: color, text: text) { EmptyView() }
    }

    private func banner<Actions: View>(symbol: String, color: Color, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(color.opacity(0.12))
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    // MARK: checks and footer

    @ViewBuilder private var checks: some View {
        let rows = editor.rows(for: file)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        switch row.state {
                        case .running: ProgressView().controlSize(.mini).frame(width: 14)
                        default: Text(icon(row.state)).foregroundStyle(color(row.state)).fontWeight(.bold).frame(width: 14)
                        }
                        Text(row.title).foregroundStyle(row.state == .fail ? Theme.danger : (row.state == .skipped ? Theme.textMuted : Theme.textPrimary))
                        Text(row.detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sidebar.opacity(0.6))
            .overlay(alignment: .top) { Theme.border.frame(height: 1) }
        }
    }

    private func icon(_ s: EditorCheckRow.State) -> String {
        switch s { case .pass: "✓"; case .fail: "✕"; case .warn: "!"; case .skipped: "–"; case .running: "" }
    }

    private func color(_ s: EditorCheckRow.State) -> Color {
        switch s { case .pass: Theme.ok; case .fail: Theme.danger; case .warn: Theme.warn; case .skipped, .running: Theme.textMuted }
    }

    private var footer: some View {
        let blocked = editor.saveBlockedReason(file)
        let dirty = editor.isDirty(file)
        return HStack(spacing: 10) {
            Text(dirty ? (blocked ?? "Checked on \(serverName) before anything is written.")
                       : "Checked on \(serverName) before anything is written.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(2)
            Spacer()
            Button("Revert") { editor.revert(file) }
                .disabled(!dirty || editor.saving)
            Button("Save") { editor.requestSave(file, redeploy: false) }
                .disabled(!editor.canSave(file)).help(blocked ?? "Save \(file.fileName) on the server")
            if !file.isEnv || true {
                Button("Save and Redeploy") { editor.requestSave(file, redeploy: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canRedeploy(file))
                    .help(blocked ?? "Save, then update the stack with docker compose up -d")
            }
        }
        .buttonStyle(.bordered).controlSize(.large).handCursor()
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }
}
