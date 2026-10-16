import AppKit
import RackoonCore
import SwiftUI

/// What the alert lists show: the active ones, the muted ones, or what was resolved in the last week.
enum AlertTab: String, CaseIterable {
    case active, muted, history

    var title: String {
        switch self {
        case .active: "Active"
        case .muted: "Muted"
        case .history: "Resolved"
        }
    }
}

extension AlertSeverity {
    @MainActor var color: Color {
        switch self {
        case .critical: Theme.danger
        case .warning: Theme.warn
        case .info: Theme.accent
        }
    }

    var symbol: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        }
    }
}

/// The sidebar's count beside Alerts: unseen warnings and worse, red when any is critical.
struct AlertBadge: Equatable {
    var count: Int
    var critical: Bool
}

/// One server's alerts (the sidebar's Alerts screen).
struct AlertsScreen: View {
    let server: Server
    /// Goes where an alert can be dealt with.
    let open: (ServerAlert) -> Void
    @State private var tab: AlertTab = .active
    private let monitor = AlertMonitor.shared

    var body: some View {
        let book = monitor.book
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AlertsHeader(title: "Alerts", subtitle: subtitle(book), server: server, tab: $tab,
                             counts: counts(book), clearable: !book.history(server: server.id).isEmpty)
                AlertList(alerts: list(book), tab: tab, showServer: false, open: open)
            }
            .padding(.horizontal, 28).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .focusedSceneValue(\.screenRefresh, { monitor.checkNow(server) })
    }

    private func list(_ book: AlertBook) -> [ServerAlert] {
        switch tab {
        case .active: book.active(server: server.id)
        case .muted: book.mutedAlerts(server: server.id)
        case .history: book.history(server: server.id)
        }
    }

    private func counts(_ book: AlertBook) -> [AlertTab: Int] {
        [.active: book.active(server: server.id).count, .muted: book.mutedAlerts(server: server.id).count,
         .history: book.history(server: server.id).count]
    }

    private func subtitle(_ book: AlertBook) -> String {
        let active = book.active(server: server.id)
        var parts = [active.isEmpty ? "Nothing needs you" : "\(active.count) active"]
        let unseen = book.unseenCount(server: server.id)
        if unseen > 0 { parts.append("\(unseen) not seen yet") }
        if let at = monitor.lastSweep[server.id] { parts.append("checked \(at.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

/// Title, tabs and the actions every alert list has: Mark All as Seen, Check Now, notifications, Clear History.
struct AlertsHeader: View {
    let title: String
    let subtitle: String
    /// nil on the Dashboard (every server).
    let server: Server?
    @Binding var tab: AlertTab
    let counts: [AlertTab: Int]
    let clearable: Bool
    private let monitor = AlertMonitor.shared
    @AppStorage(AlertNotifier.enabledKey) private var notify = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("Mark All as Seen") { monitor.acknowledgeAll(server: server?.id) }
                    .buttonStyle(.bordered).controlSize(.large).handCursor()
                    .disabled(monitor.book.unseenCount(server: server?.id) == 0)
                Button { monitor.checkNow(server) } label: {
                    if checking { ProgressView().controlSize(.small) } else { Label("Check Now", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered).controlSize(.large).handCursor()
                .disabled(checking)
                .help("Run the background checks now: services, containers, storage and certificates (⌘R). They also run every 5 minutes.")
            }
            HStack(spacing: 8) {
                ForEach(AlertTab.allCases, id: \.self) { t in
                    let on = tab == t
                    Button { tab = t } label: {
                        HStack(spacing: 5) {
                            Text(t.title)
                            Text("\(counts[t] ?? 0)").monospacedDigit().foregroundStyle(Theme.textMuted)
                        }
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(on ? Theme.selection : .clear, in: Capsule())
                        .overlay(Capsule().stroke(on ? Theme.textMuted.opacity(0.5) : Theme.border))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.pointer)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
                if tab == .history, clearable {
                    Button("Clear History") { monitor.clearHistory(server: server?.id) }
                        .buttonStyle(.bordered).controlSize(.small).handCursor()
                }
                if AlertNotifier.isAvailable {
                    Toggle(isOn: $notify) { Text("Notifications").font(.system(size: 12)) }
                        .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                        .help("A macOS notification when a new warning or critical alert appears on any server")
                } else {
                    Text("Notifications need the installed app").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
        }
    }

    private var checking: Bool {
        if let server { return monitor.checking.contains(server.id) }
        return !monitor.checking.isEmpty
    }
}

/// A list of alerts as rows: severity, title, server, how long, what it says, and Open (where to fix it).
struct AlertList: View {
    let alerts: [ServerAlert]
    let tab: AlertTab
    let showServer: Bool
    let open: (ServerAlert) -> Void

    var body: some View {
        if alerts.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: tab == .active ? "checkmark.seal.fill" : "tray").foregroundStyle(tab == .active ? Theme.ok : Theme.textMuted)
                Text(emptyText).foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 13))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                    if index > 0 { Divider() }
                    AlertRow(alert: alert, tab: tab, showServer: showServer, open: open)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
        }
    }

    private var emptyText: String {
        switch tab {
        case .active: "No alerts. Everything Rackoon checks looks fine."
        case .muted: "Nothing muted."
        case .history: "Nothing resolved in the last \(AlertBook.historyDays) days."
        }
    }
}

struct AlertRow: View {
    let alert: ServerAlert
    let tab: AlertTab
    let showServer: Bool
    let open: (ServerAlert) -> Void
    private let monitor = AlertMonitor.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.severity.symbol)
                .font(.system(size: 15))
                .foregroundStyle(tab == .history ? Theme.textMuted : alert.severity.color)
                .frame(width: 20).padding(.top, 1)
                .help(alert.severity.label)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(alert.title).font(.system(size: 14, weight: alert.acknowledged || tab != .active ? .regular : .semibold))
                        .lineLimit(1)
                    if alert.acknowledged, tab == .active {
                        Text("Seen").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.border, in: Capsule())
                    }
                }
                if let detail = alert.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(meta).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if alert.fix != nil, tab != .history {
                Button("Open") { open(alert) }
                    .buttonStyle(.bordered).controlSize(.small).handCursor()
                    .help(openHelp)
            }
            Menu {
                if tab == .active {
                    Button(alert.acknowledged ? "Mark as Not Seen" : "Mark as Seen") { monitor.acknowledge(alert, !alert.acknowledged) }
                }
                if tab != .history {
                    Button(tab == .muted ? "Unmute" : "Mute") { monitor.mute(alert, tab != .muted) }
                        .help("A muted alert is never counted or notified, until you unmute it")
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString([alert.serverName, alert.title, alert.detail].compactMap { $0 }.joined(separator: ": "), forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More for \(alert.title)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .opacity(alert.acknowledged && tab == .active ? 0.75 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            if alert.fix != nil, tab != .history { Button("Open") { open(alert) } }
            if tab == .active {
                Button(alert.acknowledged ? "Mark as Not Seen" : "Mark as Seen") { monitor.acknowledge(alert, !alert.acknowledged) }
            }
            if tab != .history { Button(tab == .muted ? "Unmute" : "Mute") { monitor.mute(alert, tab != .muted) } }
        }
    }

    /// Server, category, and how long it has been (or when it ended).
    private var meta: String {
        var parts: [String] = []
        if showServer { parts.append(alert.serverName) }
        parts.append(alert.category.title)
        if let resolved = alert.resolvedAt {
            parts.append("resolved \(resolved.formatted(.relative(presentation: .named))), lasted \(Format.duration(resolved.timeIntervalSince(alert.firstSeen)))")
        } else {
            parts.append("started \(alert.firstSeen.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private var openHelp: String {
        switch alert.fix?.screen {
        case "docker": "Open it on the Docker screen"
        case "services": "Open the Services screen"
        case "updates": "Open the Updates screen"
        case "bookmarks": "Open the Bookmarks screen"
        default: "Open the server's Overview"
        }
    }
}
