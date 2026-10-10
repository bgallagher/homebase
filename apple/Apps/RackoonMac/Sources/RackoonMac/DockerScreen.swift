import AppKit
import RackoonCore
import SwiftUI

/// The tallest card's natural height, so every card can be drawn at the same height.
private struct TileHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What the Docker screen is showing for each server, kept outside the screen so it survives switching to another
/// sidebar item and back (the screen itself is rebuilt each time): the stack page that was open, and an Add container
/// draft in progress.
@MainActor @Observable
final class DockerWorkspace {
    var openStack: [String: String] = [:]
    var drafts: [String: AddContainerModel] = [:]
}

/// Docker: a grid of stack cards, and a detail page for one stack (its containers, actions and logs).
struct DockerScreen: View {
    let server: Server
    /// The terminal theme, so logs match the terminals.
    let theme: TerminalTheme
    /// Opens a shell inside a container (a terminal tab running `docker exec`).
    let openShell: (DockerContainer) -> Void
    let workspace: DockerWorkspace
    @State private var model: DockerModel
    @State private var tileHeight: CGFloat = 0

    private var openStack: String? {
        get { workspace.openStack[server.id] }
        nonmutating set { workspace.openStack[server.id] = newValue }
    }
    private var newStack: AddContainerModel? {
        get { workspace.drafts[server.id] }
        nonmutating set { workspace.drafts[server.id] = newValue }
    }

    init(server: Server, theme: TerminalTheme, workspace: DockerWorkspace, openShell: @escaping (DockerContainer) -> Void) {
        self.server = server
        self.theme = theme
        self.workspace = workspace
        self.openShell = openShell
        _model = State(initialValue: DockerModel(server: server))
    }

    var body: some View {
        let state = model.state
        let stack = openStack.flatMap { model.stack(named: $0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let stack {
                    StackDetail(stack: stack, server: server, model: model, theme: theme, busy: state.busy,
                                back: { model.closeLogs(); openStack = nil }, openShell: openShell)
                        .id(stack.name)   // one editor (and its drafts) per stack
                } else if let newStack {
                    AddContainerScreen(model: newStack, theme: theme, back: { self.newStack = nil })
                } else {
                    overviewHeader(state.snapshot)
                }
                // On a stack's page the Output tab shows the run; the banner is for the overview.
                if stack == nil, newStack == nil, let working = model.composeWorking { ComposeBanner(text: working) }
                if let error = state.actionError { ErrorBanner(message: error) }
                if let error = state.error { ErrorBanner(message: error) }
                if stack == nil, newStack == nil {
                    if let snapshot = state.snapshot {
                        if snapshot.containers.isEmpty, model.createdStacks.isEmpty {
                            Text("No containers on this server.").foregroundStyle(Theme.textMuted)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(model.stacks) { stack in
                                StackTile(stack: stack, busy: state.busy, busyStack: state.busyStacks.contains(stack.name),
                                          height: tileHeight) { openStack = stack.name }
                            }
                        }
                        .onPreferenceChange(TileHeightKey.self) { tileHeight = $0 }
                    } else if state.error == nil {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading containers…") }
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .onAppear {
            model.start()
            if let draft = newStack { attach(draft) }   // a draft from before the screen was rebuilt
        }
        .onDisappear { model.stop() }
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
        .sheet(item: Binding(get: { model.deleting }, set: { model.deleting = $0 })) { stack in
            DeleteStackSheet(stack: stack, serverName: server.name, cancel: { model.deleting = nil },
                             run: { removal in model.deleting = nil; model.delete(stack, removal) })
        }
        .onChange(of: model.removedStack) { _, removed in
            if let removed, openStack == removed { openStack = nil }   // the stack is gone: back to the overview
        }
    }

    private func startNewStack() {
        let draft = AddContainerModel(server: server, folder: model.suggestedStackFolder)
        attach(draft)
        newStack = draft
    }

    /// Hands this screen's data and its "finished" step to a draft, which outlives the screen.
    private func attach(_ draft: AddContainerModel) {
        let model = model, workspace = workspace, serverID = server.id
        draft.attach(
            stacks: { model.stacks }, containers: { model.state.snapshot?.containers ?? [] },
            blockedReason: { model.composeBlockedReason(for: $0) },
            finished: { result in
                if result.isNew { model.adopt(result.stack) }
                if result.start { model.runDirect(.up, on: result.stack) }   // the output is already showing when the stack's page opens
                workspace.drafts[serverID] = nil
                workspace.openStack[serverID] = result.stack.name
            })
    }

    private func overviewHeader(_ snapshot: DockerSnapshot?) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Docker").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                if let snapshot {
                    let c = snapshot.containers
                    let running = c.filter(\.isRunning).count
                    let unhealthy = c.filter(\.isUnhealthy).count
                    Text("\(snapshot.stacks.filter { !$0.isStandalone }.count) stacks · \(c.count) containers · \(running) running"
                         + (unhealthy > 0 ? ", \(unhealthy) unhealthy" : ""))
                        .font(.system(size: 13)).foregroundStyle(unhealthy > 0 ? Theme.warn : Theme.textMuted)
                }
            }
            Spacer()
            Button(action: model.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered).controlSize(.large).handCursor()
            let blocked = SafetyStore.shared.readOnly ? "Read-only mode is on" : nil
            Button(action: startNewStack) { Label("Add Container", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large).handCursor()
                .disabled(blocked != nil || snapshot == nil)
                .help(blocked ?? "Add a container to a new or existing stack on \(server.name)")
        }
    }
}

// MARK: - Overview card

/// One stack as a card: containers with their CPU and memory, and a memory bar along the bottom.
private struct StackTile: View {
    let stack: DockerStack
    let busy: Set<String>
    let busyStack: Bool
    /// Height every card is drawn at (the tallest one's natural height).
    let height: CGFloat
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(stack.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(stack.configFileName ?? "").font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 4)
                    if busyStack || stack.containers.contains(where: { busy.contains($0.id) }) {
                        ProgressView().controlSize(.mini)
                    } else {
                        if !status.text.isEmpty { Text(status.text).font(.system(size: 12)).foregroundStyle(status.color) }
                        Circle().fill(status.dot).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stack.containers) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(c.service ?? c.name).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(problem(c) ? Theme.danger : Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(usage(c)).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(problem(c) ? Theme.danger : Theme.textMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Divider().overlay(Theme.border).padding(.bottom, 12)
                    HStack(spacing: 10) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.border)
                                Capsule().fill(unhealthy ? Theme.danger : Theme.ok.opacity(0.8))
                                    .frame(width: max(0, min(1, memoryFraction)) * geo.size.width)
                            }
                        }
                        .frame(height: 3)
                        Text(memoryText).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
            // Natural height, measured before the uniform height is applied (so cards can shrink again too).
            .background(GeometryReader { Color.clear.preference(key: TileHeightKey.self, value: $0.size.height) })
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(unhealthy ? Theme.danger.opacity(0.5) : (hovering ? Theme.textMuted.opacity(0.5) : Theme.border)))
            .overlay(CornerTicks().stroke(Theme.border, lineWidth: 1.5).padding(5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .onHover { hovering = $0 }
        .help("Open \(stack.name)")
    }

    private var unhealthy: Bool { stack.unhealthyCount > 0 }

    private func problem(_ c: DockerContainer) -> Bool { c.isUnhealthy }

    private func usage(_ c: DockerContainer) -> String {
        guard c.isRunning else { return c.state }
        guard let cpu = c.cpuPercent, let mem = c.memoryUsedBytes else { return "—" }
        return "\(String(format: "%.0f", cpu))% · \(Format.bytes(mem))"
    }

    private var status: (text: String, color: Color, dot: Color) {
        if stack.unhealthyCount > 0 { return ("\(stack.unhealthyCount) unhealthy", Theme.danger, Theme.danger) }
        if stack.containers.isEmpty { return ("Not started", Theme.textMuted, Theme.idle) }
        if stack.runningCount == 0 { return ("Stopped", Theme.textMuted, Theme.idle) }
        if stack.stoppedCount > 0 { return ("\(stack.stoppedCount) stopped", Theme.warn, Theme.warn) }
        return ("", Theme.ok, Theme.ok)
    }

    private var memoryUsed: Int64 { stack.containers.compactMap(\.memoryUsedBytes).reduce(0, +) }
    /// Docker reports the host's memory as the limit for containers without one, so the largest limit is the host total.
    private var memoryFraction: Double {
        guard let limit = stack.containers.compactMap(\.memoryLimitBytes).max(), limit > 0 else { return 0 }
        return Double(memoryUsed) / Double(limit)
    }
    private var memoryText: String { stack.runningCount == 0 ? "—" : Format.bytes(memoryUsed) }
}

/// Four small corner ticks, the card's signature detail from the design.
private struct CornerTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n: CGFloat = 6
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            p.move(to: CGPoint(x: x + dx * n, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * n))
        }
        return p
    }
}

// MARK: - Stack detail

private struct StackDetail: View {
    let stack: DockerStack
    let server: Server
    let model: DockerModel
    let theme: TerminalTheme
    let busy: Set<String>
    let back: () -> Void
    let openShell: (DockerContainer) -> Void
    @State private var editor: StackEditorModel
    @State private var tab: PanelSelection
    @State private var confirmDiscard = false

    init(stack: DockerStack, server: Server, model: DockerModel, theme: TerminalTheme, busy: Set<String>,
         back: @escaping () -> Void, openShell: @escaping (DockerContainer) -> Void) {
        self.stack = stack
        self.server = server
        self.model = model
        self.theme = theme
        self.busy = busy
        self.back = back
        self.openShell = openShell
        // A run that started just before this page opened (a new stack's first deploy) is already showing.
        _tab = State(initialValue: model.output?.scope == stack.name ? .output : .logs)
        _editor = State(initialValue: StackEditorModel(stack: stack, server: server, redeploy: { model.runDirect(.up, on: $0) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
                .onChange(of: model.output?.id) { _, id in
                    // Starting Pull, Update, Restart... on this stack shows its live output.
                    if id != nil, model.output?.scope == stack.name { tab = .output }
                }
            HStack(alignment: .top, spacing: 20) {
                containers.frame(width: 320)
                panel.frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: { if editor.hasUnsavedChanges { confirmDiscard = true } else { back() } }) {
                    Text("Docker").foregroundStyle(Theme.accent)
                }
                .buttonStyle(.pointer)
                .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
                    Button("Discard Changes", role: .destructive) { back() }
                    Button("Keep Editing", role: .cancel) {}
                } message: { Text("Your edits to \(stack.name)'s files have not been saved.") }
                Text("/").foregroundStyle(Theme.textMuted)
                Text(stack.name).foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 13))
            HStack(alignment: .center, spacing: 10) {
                Text(stack.name).font(.system(size: 26, weight: .bold)).tracking(-0.4).lineLimit(1)
                // A pill, centred on the lowercase body of the title (its x-height), which is what the eye reads.
                // Centring on the full text box puts it about 2 pt too high, because ascenders pull that centre up.
                Badge(text: summary.text, color: summary.color).offset(y: 2)
                Spacer()
                if !stack.isStandalone { actions }
            }
        }
    }

    private var summary: (text: String, color: Color) {
        let n = stack.containers.count
        if stack.unhealthyCount > 0 { return ("\(stack.unhealthyCount) unhealthy", Theme.danger) }
        if n == 0 { return ("Not started", Theme.textMuted) }
        if stack.runningCount == n { return (n == 1 ? "Running" : "All \(n) running", Theme.ok) }
        if stack.runningCount == 0 { return ("Stopped", Theme.textMuted) }
        return ("\(stack.runningCount) of \(n) running", Theme.warn)
    }

    @ViewBuilder private var actions: some View {
        let reason = model.composeBlockedReason(for: stack)
        let working = busy.contains { id in stack.containers.contains { $0.id == id } } || model.composeWorking != nil
        HStack(spacing: 8) {
            if working { ProgressView().controlSize(.small) }
            Button("Pull Images") { model.request(.pull, on: stack) }.handCursor()
            Button("Rebuild") { model.request(.rebuild, on: stack) }.handCursor()
            Button("Restart") { model.request(.restart, on: stack) }.handCursor()
            Menu {
                Button("Update") { model.request(.up, on: stack) }
                Divider()
                Button("Recreate All Containers…", role: .destructive) { model.request(.recreate, on: stack) }
                Button("Delete Stack…", role: .destructive) { model.requestDelete(stack) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).handCursor()
        }
        .buttonStyle(.bordered).controlSize(.large)
        .disabled(reason != nil)
        .help(reason ?? "Actions for the whole \(stack.name) stack")
    }

    // MARK: containers

    private var containers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTAINERS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
            VStack(spacing: 0) {
                ForEach(stack.containers) { c in
                    ContainerCard(container: c, stack: stack, busy: busy.contains(c.id), model: model, openShell: openShell)
                    if c.id != stack.containers.last?.id { Divider().overlay(Theme.border) }
                }
            }
            .card()
        }
    }

    // MARK: right panel

    private var panel: some View {
        StackPanel(stack: stack, model: model, editor: editor, theme: theme, busy: busy, serverName: server.name, tab: $tab)
    }
}

/// One container in the detail list: status dot, name, usage, image, and text actions.
private struct ContainerCard: View {
    let container: DockerContainer
    let stack: DockerStack
    let busy: Bool
    let model: DockerModel
    let openShell: (DockerContainer) -> Void

    var body: some View {
        let showingLogs = model.logTarget?.id == container.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(container.service ?? container.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(usage).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
            }
            Text(container.image).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .lineLimit(1).truncationMode(.middle).padding(.top, 4).padding(.leading, 15)
            HStack(spacing: 14) {
                LinkAction(title: "Logs", tint: showingLogs ? Theme.accent : Theme.textSecondary) { model.toggleLogs(for: container) }
                LinkAction(title: "Shell", enabled: container.isRunning) { openShell(container) }
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    LinkAction(title: "Restart", mutates: true) { model.request(.restart, on: container) }
                    if model.canRebuild(container, in: stack) {
                        LinkAction(title: "Rebuild", mutates: true) { model.requestRebuild(of: container, in: stack) }
                    }
                    if container.isRunning {
                        LinkAction(title: "Stop", mutates: true) { model.request(.stop, on: container) }
                    } else {
                        LinkAction(title: "Start", mutates: true) { model.request(.start, on: container) }
                    }
                }
            }
            .padding(.top, 10).padding(.leading, 15)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(showingLogs ? Theme.accent.opacity(0.08) : .clear)
    }

    private var dot: Color {
        if container.isUnhealthy { return Theme.danger }
        switch container.state {
        case "running": return container.health == "starting" ? Theme.warn : Theme.ok
        case "restarting", "paused": return Theme.warn
        default: return Theme.idle
        }
    }

    private var usage: String {
        guard container.isRunning else { return container.state }
        guard let cpu = container.cpuPercent, let mem = container.memoryUsedBytes else { return "—" }
        return "\(String(format: "%.0f", cpu))% · \(Format.bytes(mem))"
    }
}

/// A small text action under a container. Mutating ones disable themselves in read-only mode.
private struct LinkAction: View {
    let title: String
    var tint: Color = Theme.textSecondary
    var mutates = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        let blocked = (mutates && SafetyStore.shared.readOnly) || !enabled
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .foregroundStyle(tint)
        .disabled(blocked)
        .opacity(blocked ? 0.4 : 1)
        .help(mutates && SafetyStore.shared.readOnly ? "Read-only mode is on" : (!enabled ? "The container is not running" : title))
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    /// Changes something on the server, so it is disabled in read-only mode.
    var mutates = false
    let action: () -> Void

    var body: some View {
        let blocked = mutates && SafetyStore.shared.readOnly
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .foregroundStyle(tint)
        .disabled(blocked)
        .opacity(blocked ? 0.4 : 1)
        .help(blocked ? "Read-only mode is on" : help)
    }
}

private struct ComposeBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fontWeight(.medium)
                Text("This can take a few minutes. It keeps running on the server if you leave this screen.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(12).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct LogPanel: View {
    let model: DockerModel
    let container: DockerContainer
    let theme: TerminalTheme
    let busy: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(model.logsLive ? Theme.ok : Theme.idle).frame(width: 7, height: 7)
                Text(container.name).fontWeight(.semibold).lineLimit(1).layoutPriority(1)
                Text(model.logsLive ? "Live" : "Ended").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                Spacer(minLength: 4)
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy logs",
                           tint: copied ? Theme.ok : Theme.textSecondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Restart \(container.name)", mutates: true) {
                        model.request(.restart, on: container)
                    }
                }
                IconButton(symbol: "xmark", help: "Close logs", action: model.closeLogs)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.sidebar)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            if let error = model.logError { ErrorBanner(message: error).padding(12) }
            ScrollView {
                Text(styled)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color(nsColor: theme.backgroundRGB.nsColor))
        }
    }

    /// Lines coloured from the active terminal theme: errors red, warnings yellow, debug dimmed,
    /// timestamps muted, everything else in the theme's foreground.
    private var styled: AttributedString {
        let lines = model.logLines
        guard !lines.isEmpty else {
            var waiting = AttributedString("Waiting for output…")
            waiting.foregroundColor = Color(nsColor: theme.foregroundRGB.nsColor).opacity(0.5)
            return waiting
        }
        let ansi = theme.ansiRGB
        let fg = Color(nsColor: theme.foregroundRGB.nsColor)
        let muted = fg.opacity(0.45)
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            let level = LogLineParser.level(of: line)
            let base: Color = switch level {
            case .error: Color(nsColor: ansi[9].nsColor)    // bright red
            case .warn: Color(nsColor: ansi[11].nsColor)    // bright yellow
            case .debug: muted
            case .info, nil: fg
            }
            let split = LogLineParser.timestampLength(in: line)
            let cut = line.index(line.startIndex, offsetBy: split)
            if split > 0 {
                var ts = AttributedString(String(line[..<cut]))
                ts.foregroundColor = level == .error || level == .warn ? base.opacity(0.7) : muted
                out += ts
            }
            var rest = AttributedString(String(line[cut...]))
            rest.foregroundColor = base
            if level == .error { rest.font = .system(size: 12, weight: .medium, design: .monospaced) }
            out += rest
            if i < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }
}
