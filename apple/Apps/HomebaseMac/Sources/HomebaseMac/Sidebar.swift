import HomebaseCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case overview, docker, updates, bookmarks, terminal, command, alerts, security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .docker: "Docker"
        case .updates: "Updates"
        case .bookmarks: "Bookmarks"
        case .terminal: "Terminal"
        case .command: "Command"
        case .alerts: "Alerts"
        case .security: "Security"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .docker: "shippingbox"
        case .updates: "arrow.down.circle"
        case .bookmarks: "bookmark"
        case .terminal: "terminal"
        case .command: "chevron.left.forwardslash.chevron.right"
        case .alerts: "bell"
        case .security: "shield"
        }
    }

    /// Screens that exist today. The rest are shown as "Soon" so the layout matches the design.
    var isAvailable: Bool {
        switch self {
        case .overview, .docker, .terminal, .command: true
        default: false
        }
    }
}

enum ConnectionStatus { case connecting, connected, failing, none }

struct Sidebar: View {
    @Binding var selection: Screen
    let servers: [Server]
    let selectedID: String?
    let status: ConnectionStatus
    let onSelect: (Server) -> Void
    let onRemove: (Server) -> Void
    let onAddServer: () -> Void

    private var selectedName: String? { servers.first { $0.id == selectedID }?.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Servers")
            ForEach(servers) { server in
                let isSelected = server.id == selectedID
                Button { onSelect(server) } label: {
                    HStack(spacing: 10) {
                        StatusDot(status: isSelected ? status : .none, glow: isSelected)
                        Text(server.name).fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pointer)
                .contextMenu { Button("Remove \(server.name)", role: .destructive) { onRemove(server) } }
            }
            Button(action: onAddServer) {
                Label("Add server", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .foregroundStyle(Theme.textMuted)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .padding(.top, 4)

            if let name = selectedName {
                Divider().padding(.vertical, 12)
                SectionLabel(name)
                ForEach(Screen.allCases) { screen in
                    NavRow(screen: screen, selected: selection == screen) {
                        if screen.isAvailable { selection = screen }
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 44).padding(.bottom, 16).padding(.horizontal, 12) // top clears the traffic lights
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .foregroundStyle(Theme.textPrimary)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 8).padding(.bottom, 6)
    }
}

private struct NavRow: View {
    let screen: Screen
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: screen.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text(screen.title).fontWeight(selected ? .semibold : .regular)
                Spacer()
                if !screen.isAvailable {
                    Text("Soon").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.border, in: Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(screen.isAvailable ? Theme.textPrimary : Theme.textMuted)
            .background(selected ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .disabled(!screen.isAvailable)
    }
}

struct StatusDot: View {
    let status: ConnectionStatus
    var glow = false

    var body: some View {
        let color: Color = switch status {
        case .connected: Theme.ok
        case .failing: Theme.danger
        case .connecting, .none: Theme.idle
        }
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: glow && status == .connected ? color.opacity(0.5) : .clear, radius: 3)
    }
}
