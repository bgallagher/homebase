import AppKit
import HomebaseCore
import SwiftUI

struct DockerScreen: View {
    let server: Server
    @State private var model: DockerModel
    @State private var collapsed: Set<String> = []
    @State private var confirmStop: DockerContainer?

    init(server: Server) {
        self.server = server
        _model = State(initialValue: DockerModel(server: server))
    }

    var body: some View {
        let state = model.state
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(state.snapshot)
                    if let error = state.actionError { ErrorBanner(message: error) }
                    if let error = state.error { ErrorBanner(message: error) }
                    if let snapshot = state.snapshot {
                        if snapshot.containers.isEmpty {
                            Text("No containers on this server.").foregroundStyle(Theme.textMuted)
                        }
                        ForEach(snapshot.stacks) { stack in
                            StackCard(stack: stack, collapsed: collapsed.contains(stack.id),
                                      toggle: { toggle(stack.id) }, model: model,
                                      selectedID: model.logTarget?.id,
                                      busy: state.busy, askStop: { confirmStop = $0 })
                        }
                    } else if state.error == nil {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading containers…") }
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let target = model.logTarget {
                LogPanel(model: model, container: target, busy: state.busy.contains(target.id))
                    .frame(height: 280)
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog("Stop \(confirmStop?.name ?? "")?", isPresented: Binding(
            get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }), presenting: confirmStop) { c in
            Button("Stop \(c.name)", role: .destructive) { model.perform(.stop, on: c) }
        } message: { c in
            Text("\(c.name) will stop until you start it again.")
        }
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
    let busy: Set<String>
    let askStop: (DockerContainer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(Theme.textMuted)
                    Text(stack.name).fontWeight(.semibold)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    Spacer()
                    summaryBadge
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointer)

            if !collapsed {
                Divider().overlay(Theme.border)
                ForEach(stack.containers) { c in
                    ContainerRow(container: c, selected: c.id == selectedID, busy: busy.contains(c.id),
                                 model: model, askStop: askStop)
                    if c.id != stack.containers.last?.id { Divider().overlay(Theme.border).padding(.leading, 14) }
                }
            }
        }
        .card()
    }

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
    let busy: Bool
    let model: DockerModel
    let askStop: (DockerContainer) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.service ?? container.name).fontWeight(.medium).lineLimit(1)
                Text(container.image).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusBadge.frame(width: 110, alignment: .leading)

            Text(resources).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .frame(width: 130, alignment: .leading)

            Text(ports).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
                .lineLimit(1).frame(width: 130, alignment: .leading)

            HStack(spacing: 2) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Restart \(container.name)") {
                        model.perform(.restart, on: container)
                    }
                    if container.isRunning {
                        IconButton(symbol: "stop.fill", help: "Stop \(container.name)") { askStop(container) }
                    } else {
                        IconButton(symbol: "play.fill", help: "Start \(container.name)") {
                            model.perform(.start, on: container)
                        }
                    }
                }
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(selected ? Theme.accent.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.showLogs(for: container) }
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .foregroundStyle(Theme.textSecondary)
        .help(help)
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
    let busy: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(model.logsLive ? Theme.ok : Theme.idle).frame(width: 7, height: 7)
                Text(container.name).fontWeight(.semibold)
                Text(model.logsLive ? "Live · last 100 lines" : "Stream ended").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                Spacer()
                PanelButton(title: copied ? "Copied" : "Copy logs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logs.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                PanelButton(title: busy ? "Restarting…" : "Restart \(container.name)") {
                    model.perform(.restart, on: container)
                }
                .disabled(busy)
                IconButton(symbol: "xmark", help: "Close logs", action: model.closeLogs)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.sidebar)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            if let error = model.logError { ErrorBanner(message: error).padding(12) }
            ScrollView {
                Text(model.logs.text.isEmpty ? "Waiting for output…" : model.logs.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(model.logs.text.isEmpty ? Theme.textMuted : Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color.black.opacity(0.35))
        }
    }
}

private struct PanelButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 26)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.pointer)
    }
}
