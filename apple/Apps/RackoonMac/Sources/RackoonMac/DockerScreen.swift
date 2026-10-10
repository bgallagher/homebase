import AppKit
import RackoonCore
import SwiftUI

struct DockerScreen: View {
    let server: Server
    /// The terminal theme, so logs match the terminals.
    let theme: TerminalTheme
    @State private var model: DockerModel
    @State private var collapsed: Set<String> = []

    init(server: Server, theme: TerminalTheme) {
        self.server = server
        self.theme = theme
        _model = State(initialValue: DockerModel(server: server))
    }

    var body: some View {
        let state = model.state
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(state.snapshot)
                    if let working = model.composeWorking { ComposeBanner(text: working) }
                    if let error = state.actionError { ErrorBanner(message: error) }
                    if let error = state.error { ErrorBanner(message: error) }
                    if let snapshot = state.snapshot {
                        if snapshot.containers.isEmpty {
                            Text("No containers on this server.").foregroundStyle(Theme.textMuted)
                        }
                        ForEach(snapshot.stacks) { stack in
                            StackCard(stack: stack, collapsed: collapsed.contains(stack.id),
                                      toggle: { toggle(stack.id) }, model: model,
                                      selectedID: model.logTarget?.id, compact: model.logTarget != nil,
                                      busy: state.busy)
                        }
                    } else if state.error == nil {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading containers…") }
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 440)
            if let target = model.logTarget {
                LogPanel(model: model, container: target, theme: theme, busy: state.busy.contains(target.id))
                    .frame(minWidth: 320, idealWidth: 460)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func header(_ snapshot: DockerSnapshot?) -> some View {
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
            Button(action: model.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise").fontWeight(.medium)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            }
            .buttonStyle(.pointer)
        }
    }
}

private struct StackCard: View {
    let stack: DockerStack
    let collapsed: Bool
    let toggle: () -> Void
    let model: DockerModel
    let selectedID: String?
    let compact: Bool
    let busy: Set<String>

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(Theme.textMuted)
                        Text(stack.name).fontWeight(.semibold)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        Spacer()
                        summaryBadge
                    }
                    .padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pointer)
                if !stack.isStandalone { stackMenu }
            }

            if !collapsed {
                Divider().overlay(Theme.border)
                ForEach(stack.containers) { c in
                    ContainerRow(container: c, selected: c.id == selectedID, compact: compact, busy: busy.contains(c.id) || stackBusy,
                                 model: model)
                    if c.id != stack.containers.last?.id { Divider().overlay(Theme.border).padding(.leading, 14) }
                }
            }
        }
        .card()
    }

    /// Whole-stack actions. A native menu: items are disabled with the reason shown first when they cannot run.
    private var stackMenu: some View {
        let reason = model.composeBlockedReason(for: stack)
        let working = stackBusy || stack.containers.contains { busy.contains($0.id) }
        return Group {
            if working {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                Menu {
                    if let reason { Text(reason) }
                    Button("Pull Images") { model.request(.pull, on: stack) }
                    Button("Update") { model.request(.up, on: stack) }
                    Button("Rebuild") { model.request(.rebuild, on: stack) }
                    Divider()
                    Button("Recreate All Containers…", role: .destructive) { model.request(.recreate, on: stack) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .disabled(reason != nil)
                .foregroundStyle(Theme.textSecondary)
                .help(reason ?? "Pull, update, rebuild or recreate \(stack.name)")
                .handCursor()
            }
        }
        .padding(.trailing, 12)
    }

    /// A whole-stack compose action is running on this stack (matched by project name, see DockerState.busyStacks).
    private var stackBusy: Bool { model.state.busyStacks.contains(stack.name) }

    private var subtitle: String {
        let n = stack.containers.count
        let count = "\(n) container\(n == 1 ? "" : "s")"
        return [stack.configFileName, count].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var summaryBadge: some View {
        if stack.unhealthyCount > 0 {
            Badge(text: "\(stack.unhealthyCount) unhealthy", color: Theme.danger)
        } else if stack.stoppedCount > 0 {
            Badge(text: "\(stack.stoppedCount) stopped", color: Theme.textMuted)
        } else {
            Badge(text: "All running", color: Theme.ok)
        }
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let selected: Bool
    let compact: Bool
    let busy: Bool
    let model: DockerModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.service ?? container.name).fontWeight(.medium).lineLimit(1)
                Text(container.image).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusBadge.frame(width: compact ? 90 : 110, alignment: .leading)

            Text(resources).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).frame(width: compact ? 100 : 130, alignment: .leading)

            if !compact {
                Text(ports).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).frame(width: 130, alignment: .leading)
            }

            HStack(spacing: 2) {
                IconButton(symbol: "text.alignleft", help: "Logs for \(container.name)",
                           tint: selected ? Theme.accent : Theme.textSecondary) {
                    model.toggleLogs(for: container)
                }
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Restart \(container.name)", mutates: true) {
                        model.request(.restart, on: container)
                    }
                    if container.isRunning {
                        IconButton(symbol: "stop.fill", help: "Stop \(container.name)", mutates: true) { model.request(.stop, on: container) }
                    } else {
                        IconButton(symbol: "play.fill", help: "Start \(container.name)", mutates: true) {
                            model.request(.start, on: container)
                        }
                    }
                }
            }
            .frame(width: 94, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(selected ? Theme.accent.opacity(0.12) : (hovering ? Theme.selection.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .handCursor()
        .onTapGesture { model.toggleLogs(for: container) }
        .help("Click to follow logs")
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            if container.isUnhealthy { return ("Unhealthy", Theme.danger) }
            switch container.state {
            case "running": return (container.health == "starting" ? "Starting" : "Running", container.health == "starting" ? Theme.warn : Theme.ok)
            case "restarting": return ("Restarting", Theme.warn)
            case "paused": return ("Paused", Theme.warn)
            default: return (container.state.capitalized, Theme.textMuted)
            }
        }()
        return Badge(text: text, color: color)
    }

    private var resources: String {
        guard container.isRunning, let cpu = container.cpuPercent, let mem = container.memoryUsedBytes else { return "—" }
        return "\(String(format: "%.0f", cpu))% · \(Format.bytes(mem))"
    }

    private var ports: String {
        // TCP and UDP on the same port are separate mappings but read the same here.
        var seen = Set<String>()
        return container.ports.map { "\($0.hostPort)→\($0.containerPort)" }
            .filter { seen.insert($0).inserted }.joined(separator: ", ")
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

private struct LogPanel: View {
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
