import AppKit
import Charts
import RackoonCore
import SwiftUI

/// Every server at once, as a carousel of four pages: Health (uptime and resource history), Servers (one tile each),
/// Docker (every stack, grouped by server) and Bookmarks (grouped by server). Reads what the polls already have: the
/// selected server's live poll, the others' once-a-minute poll (`FleetMonitor`), and, while the Docker or Bookmarks page
/// is showing, each answering server's Docker poll.
struct DashboardScreen: View {
    let model: AppModel
    let workspace: DockerWorkspace
    let theme: TerminalTheme
    let openServer: (Server, Screen) -> Void
    let openStack: (Server, String) -> Void

    enum Page: String, CaseIterable, Identifiable {
        case health, servers, docker, bookmarks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .health: "Health"
            case .servers: "Servers"
            case .docker: "Docker"
            case .bookmarks: "Bookmarks"
            }
        }
        var symbol: String {
            switch self {
            case .health: "waveform.path.ecg"
            case .servers: "server.rack"
            case .docker: "shippingbox"
            case .bookmarks: "bookmark"
            }
        }
    }

    @AppStorage("dashboardPage") private var savedPage = Page.health.rawValue
    @State private var page: Page?

    var body: some View {
        let rows = model.fleetRows
        VStack(alignment: .leading, spacing: 0) {
            header(rows)
                .padding(.horizontal, 32).padding(.top, Theme.pageTop).padding(.bottom, 14)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Page.allCases) { p in
                        content(p, rows: rows)
                            .containerRelativeFrame(.horizontal)
                            .id(p)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.never)
        }
        .foregroundStyle(Theme.textPrimary)
        .onAppear { page = Page(rawValue: savedPage) ?? .health }
        .onChange(of: page) { _, new in if let new { savedPage = new.rawValue } }
        .focusedSceneValue(\.screenRefresh, {
            model.refresh()
            model.fleet.refreshAll()
        })
    }

    // MARK: header

    private func header(_ rows: [FleetRow]) -> some View {
        let online = rows.filter(\.isOnline).count
        let down = rows.filter { $0.state.error != nil }.count
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                HStack(spacing: 6) {
                    Text("\(rows.count) server\(rows.count == 1 ? "" : "s") · \(online) online")
                    if down > 0 {
                        Text("·")
                        Circle().fill(Theme.danger).frame(width: 6, height: 6)
                        Text("\(down) not answering").foregroundStyle(Theme.danger)
                    }
                }
                .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            pager
        }
    }

    private var current: Page { page ?? .health }

    /// The page tabs with previous and next arrows; swiping sideways on the trackpad pages too.
    private var pager: some View {
        HStack(spacing: 6) {
            arrow("chevron.left", to: Page.allCases.firstIndex(of: current).flatMap { $0 > 0 ? Page.allCases[$0 - 1] : nil })
            HStack(spacing: 2) {
                ForEach(Page.allCases) { p in
                    Button { withAnimation(.easeInOut(duration: 0.25)) { page = p } } label: {
                        Label(p.title, systemImage: p.symbol)
                            .font(.system(size: 12, weight: current == p ? .semibold : .regular))
                            .foregroundStyle(current == p ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(current == p ? Theme.selection : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pointer)
                    .accessibilityAddTraits(current == p ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().stroke(Theme.border))
            arrow("chevron.right", to: Page.allCases.firstIndex(of: current).flatMap { $0 < Page.allCases.count - 1 ? Page.allCases[$0 + 1] : nil })
        }
    }

    private func arrow(_ symbol: String, to target: Page?) -> some View {
        Button { if let target { withAnimation(.easeInOut(duration: 0.25)) { page = target } } } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Theme.card, in: Circle())
                .overlay(Circle().stroke(Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.pointer)
        .disabled(target == nil)
        .opacity(target == nil ? 0.35 : 1)
        .help(target.map { "Show \($0.title)" } ?? "")
    }

    @ViewBuilder private func content(_ p: Page, rows: [FleetRow]) -> some View {
        ScrollView(.vertical) {
            Group {
                switch p {
                case .health: HealthPage(rows: rows, openServer: { openServer($0, .overview) })
                case .servers: ServersPage(rows: rows, openServer: openServer)
                case .docker: DockerPage(rows: rows, workspace: workspace, openServer: openServer, openStack: openStack)
                case .bookmarks: BookmarksPage(rows: rows, workspace: workspace)
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared pieces

private func lightStatus(_ row: FleetRow) -> ConnectionStatus {
    if row.blocked != nil || row.state.error != nil { return .failing }
    return row.isOnline ? .connected : .connecting
}

/// A thin meter with its value written beside it, so the colour is never the only signal.
private struct Meter: View {
    let label: String
    let fraction: Double?
    let value: String
    var warnAt = 0.8
    var dangerAt = 0.9

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textMuted).frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    if let fraction {
                        Capsule().fill(tint(fraction)).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                    }
                }
            }
            .frame(height: 6)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).frame(minWidth: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private func tint(_ f: Double) -> Color { f >= dangerAt ? Theme.danger : (f >= warnAt ? Theme.warn : Theme.accent) }
}

/// A small headline number with a caption: the dashboard's top row.
private struct Headline: View {
    let title: String
    let value: String
    var detail: String = ""
    var detailTint: Color = Theme.textMuted
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            Text(value).font(.system(size: 24, weight: .bold)).tracking(-0.4).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            // The bar's row is kept even without a bar, so every tile in a row is the same height.
            GeometryReader { geo in
                if let fraction {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                        Capsule().fill(fraction >= 0.9 ? Theme.danger : (fraction >= 0.8 ? Theme.warn : Theme.accent))
                            .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                    }
                }
            }
            .frame(height: 6)
            Text(detail.isEmpty ? " " : detail).font(.system(size: 12)).foregroundStyle(detailTint).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The headline tiles: all in one row when each gets at least 160 pt, otherwise two even rows (never one orphan).
private struct TileGrid<Content: View>: View {
    let count: Int
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 1200

    var body: some View {
        let perRow = width >= CGFloat(count) * 160 ? count : Int((Double(count) / 2).rounded(.up))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: max(perRow, 1)), spacing: 12) {
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct SectionHeading: View {
    let text: String
    var note: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textSecondary)
            if !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
        }
        .padding(.top, 8)
    }
}

/// "last seen 3 hours ago" for a server that is not answering, or why it is not polled.
private func offlineNote(_ row: FleetRow) -> String {
    if let blocked = row.blocked { return blocked }
    if row.state.error != nil {
        return row.state.updatedAt.map { "Not answering · last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Not answering"
    }
    return row.state.overview == nil ? "Checking…" : "Checking… (showing the last reading)"
}

// MARK: - Health

private struct HealthPage: View {
    let rows: [FleetRow]
    let openServer: (Server) -> Void

    var body: some View {
        let t = FleetTotals.of(rows.map(\.state))
        VStack(alignment: .leading, spacing: 14) {
            TileGrid(count: 6) {
                Headline(title: "Online", value: "\(t.online) / \(t.servers)",
                         detail: t.online == t.servers ? "Every server answers" : "\(t.servers - t.online) not answering",
                         detailTint: t.online == t.servers ? Theme.textMuted : Theme.danger)
                Headline(title: "CPU", value: t.cpuPercent.map(Format.percent) ?? "—", detail: "Weighted by cores",
                         fraction: t.cpuPercent.map { $0 / 100 })
                Headline(title: "Memory", value: Format.bytes(t.memoryUsed),
                         detail: "of \(Format.bytes(t.memoryTotal))",
                         fraction: t.memoryTotal > 0 ? Double(t.memoryUsed) / Double(t.memoryTotal) : nil)
                Headline(title: "Disk", value: Format.bytes(t.diskUsed),
                         detail: "of \(Format.bytes(t.diskTotal))",
                         fraction: t.diskTotal > 0 ? Double(t.diskUsed) / Double(t.diskTotal) : nil)
                Headline(title: "Updates", value: "\(t.updates)",
                         detail: t.securityUpdates > 0 ? "\(t.securityUpdates) security" : "None for security",
                         detailTint: t.securityUpdates > 0 ? Theme.warn : Theme.textMuted)
                Headline(title: "Needs attention", value: "\(t.rebootRequired + t.unhealthyContainers)",
                         detail: [t.rebootRequired > 0 ? "\(t.rebootRequired) reboot\(t.rebootRequired == 1 ? "" : "s")" : nil,
                                  t.unhealthyContainers > 0 ? "\(t.unhealthyContainers) unhealthy" : nil]
                                    .compactMap { $0 }.joined(separator: " · "),
                         detailTint: t.rebootRequired + t.unhealthyContainers > 0 ? Theme.warn : Theme.textMuted)
            }
            SectionHeading(text: "Uptime and load", note: "The last hour, one check a minute, since Rackoon opened")
            VStack(spacing: 10) {
                ForEach(rows) { row in HealthRow(row: row, open: { openServer(row.server) }) }
            }
        }
    }
}

/// One server like Uptime Kuma's list (a heartbeat bar and uptime %) beside Beszel-style CPU and memory charts.
private struct HealthRow: View {
    let row: FleetRow
    let open: () -> Void

    var body: some View {
        let samples = row.history.samples
        let o = row.state.overview
        HStack(alignment: .center, spacing: 18) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(status: lightStatus(row), glow: row.isOnline)
                        Text(row.server.name).fontWeight(.semibold).lineLimit(1)
                    }
                    Text(row.history.uptimeFraction.map { String(format: "%.1f%% up", $0 * 100) } ?? "No checks yet")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle((row.history.uptimeFraction ?? 1) < 1 ? Theme.warn : Theme.textSecondary)
                    Text(row.isOnline ? (o.map { "Booted \(Format.uptime($0.uptimeSeconds)) ago" } ?? "") : offlineNote(row))
                        .font(.system(size: 11)).foregroundStyle(row.isOnline ? Theme.textMuted : Theme.danger)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 190, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .help("Open \(row.server.name)'s Overview")
            Heartbeat(samples: samples)
                .frame(maxWidth: .infinity)
            Sparkline(title: "CPU", unit: "%", points: samples.compactMap { s in s.cpuPercent.map { (s.at, $0) } },
                      current: row.isOnline ? row.state.cpuPercent : nil)
                .frame(width: 150)
            Sparkline(title: "Memory", unit: "%", points: samples.compactMap { s in s.memoryFraction.map { (s.at, $0 * 100) } },
                      current: row.isOnline ? o.map { $0.memory.usedFraction * 100 } : nil)
                .frame(width: 150)
            VStack(alignment: .leading, spacing: 4) {
                Text("Fullest disk").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                if let disk = o?.disks.max(by: { $0.usePercent < $1.usePercent }) {
                    Text("\(disk.usePercent)%").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(disk.usePercent > Attention.diskThresholdPercent ? Theme.danger : Theme.textPrimary)
                    Text(disk.mount).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted).lineLimit(1)
                } else {
                    Text("—").foregroundStyle(Theme.textMuted)
                }
            }
            .frame(width: 84, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .card()
    }
}

/// The last hour of checks as thin bars, newest on the right: up, down, or not checked yet.
private struct Heartbeat: View {
    let samples: [HealthSample]

    var body: some View {
        let slots = HealthHistory.capacity
        let padded: [HealthSample?] = Array(repeating: nil, count: max(0, slots - samples.count)) + samples.map { Optional($0) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Array(padded.enumerated()), id: \.offset) { _, sample in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(sample.map { $0.up ? Theme.ok : Theme.danger } ?? Theme.border)
                        .frame(maxWidth: 6)
                        .frame(height: 22)
                        .help(sample.map { "\($0.at.formatted(date: .omitted, time: .shortened)): \($0.up ? "up" : "not answering")" } ?? "No check yet")
                }
            }
            HStack {
                Text("1 h ago")
                Spacer()
                Text("now")
            }
            .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(samples.filter(\.up).count) of \(samples.count) checks answered in the last hour")
    }
}

/// A single series over the last hour on a fixed 0–100 scale, with its current value in the title. Hover reads a point.
private struct Sparkline: View {
    let title: String
    let unit: String
    let points: [(Date, Double)]
    let current: Double?
    @State private var hover: (Date, Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Spacer()
                Text(readout).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
            }
            if points.count < 2 {
                RoundedRectangle(cornerRadius: 4).fill(Theme.border.opacity(0.4))
                    .overlay(Text("Collecting…").font(.system(size: 10)).foregroundStyle(Theme.textMuted))
                    .frame(height: 34)
            } else {
                Chart {
                    ForEach(points, id: \.0) { at, value in
                        AreaMark(x: .value("Time", at), y: .value(title, value))
                            .foregroundStyle(Theme.accent.opacity(0.16))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", at), y: .value(title, value))
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                    }
                    if let hover {
                        RuleMark(x: .value("Time", hover.0)).foregroundStyle(Theme.textMuted.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value("Time", hover.0), y: .value(title, hover.1)).foregroundStyle(Theme.accent).symbolSize(24)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 34)
                .chartOverlay { proxy in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let date: Date = proxy.value(atX: location.x) {
                                    hover = points.min { abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date)) }
                                }
                            case .ended: hover = nil
                            }
                        }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(readout)")
    }

    private var readout: String {
        if let hover { return "\(String(format: "%.0f", hover.1))\(unit) at \(hover.0.formatted(date: .omitted, time: .shortened))" }
        return current.map { String(format: "%.0f", $0) + unit } ?? "—"
    }
}

// MARK: - Servers

private struct ServersPage: View {
    let rows: [FleetRow]
    let openServer: (Server, Screen) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14, alignment: .top)], spacing: 14) {
            ForEach(rows) { row in ServerTile(row: row, open: { openServer(row.server, .overview) }) }
        }
    }
}

private struct ServerTile: View {
    let row: FleetRow
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let o = row.state.overview
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(status: lightStatus(row), glow: row.isOnline)
                    Text(row.server.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.textSecondary : Theme.textMuted.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text([o?.hostname, o?.os.prettyName].compactMap { $0 }.joined(separator: " · ").ifEmpty(row.server.address))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    HStack(spacing: 10) {
                        if let ip = o?.ipAddress { addressLabel("IP", ip) }
                        if let ts = o?.tailscaleIP { addressLabel("Tailscale", ts) }
                        if o?.ipAddress == nil, o?.tailscaleIP == nil { addressLabel("Host", row.server.address) }
                    }
                }
                if !row.isOnline {
                    Text(offlineNote(row)).font(.system(size: 12))
                        .foregroundStyle(row.state.error != nil || row.blocked != nil ? Theme.danger : Theme.textMuted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let o {
                    VStack(spacing: 6) {
                        Meter(label: "CPU", fraction: row.state.cpuPercent.map { $0 / 100 },
                              value: row.state.cpuPercent.map(Format.percent) ?? "—")
                        Meter(label: "RAM", fraction: o.memory.usedFraction,
                              value: "\(Format.bytes(o.memory.usedBytes)) / \(Format.bytes(o.memory.totalBytes))")
                        if let disk = o.disks.max(by: { $0.usePercent < $1.usePercent }) {
                            Meter(label: "Disk", fraction: Double(disk.usePercent) / 100,
                                  value: "\(disk.usePercent)% \(disk.mount)",
                                  warnAt: 0.75, dangerAt: Double(Attention.diskThresholdPercent) / 100)
                        }
                    }
                    .opacity(row.isOnline ? 1 : 0.55)
                    Text("Up \(Format.uptime(o.uptimeSeconds)) · load \(Format.load(o.load1)) · \(o.cores) cores")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    badges(o)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(row.state.error != nil ? Theme.danger.opacity(0.5) : (hovering ? Theme.textMuted.opacity(0.5) : Theme.border)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .onHover { hovering = $0 }
        .help("Open \(row.server.name)'s Overview")
    }

    private func addressLabel(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.textMuted)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 11)).lineLimit(1)
    }

    private func badges(_ o: Overview) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeList(o) }
            VStack(alignment: .leading, spacing: 6) { badgeList(o) }
        }
    }

    @ViewBuilder private func badgeList(_ o: Overview) -> some View {
        Group {
            if o.pendingUpdates > 0 {
                Badge(text: o.securityUpdates > 0 ? "\(o.pendingUpdates) updates, \(o.securityUpdates) security" : "\(o.pendingUpdates) updates",
                      color: o.securityUpdates > 0 ? Theme.warn : Theme.accent)
            }
            if o.rebootRequired { Badge(text: "Reboot required", color: Theme.warn) }
            if !o.unhealthyContainers.isEmpty { Badge(text: "\(o.unhealthyContainers.count) unhealthy", color: Theme.danger) }
            if o.pendingUpdates == 0, !o.rebootRequired, o.unhealthyContainers.isEmpty {
                Badge(text: "Up to date", color: Theme.ok)
            }
        }
        .fixedSize()
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

// MARK: - Docker data for every answering server

/// Keeps each answering server's Docker poll running while a page that shows Docker data is visible, attaching servers
/// as they come online and detaching all of them when the page goes away.
private struct DockerAttachment: ViewModifier {
    let rows: [FleetRow]
    let workspace: DockerWorkspace
    @State private var attached: [String: DockerModel] = [:]

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: rows.filter(\.isOnline).map(\.id)) { _, _ in sync() }
            .onDisappear {
                for model in attached.values { model.detach() }
                attached = [:]
            }
    }

    private func sync() {
        for row in rows where row.isOnline {
            let model = workspace.model(for: row.server)
            if attached[row.id] !== model {
                attached[row.id]?.detach()
                model.attach()
                attached[row.id] = model
            }
        }
    }
}

// MARK: - Docker

private struct DockerPage: View {
    let rows: [FleetRow]
    let workspace: DockerWorkspace
    let openServer: (Server, Screen) -> Void
    let openStack: (Server, String) -> Void

    var body: some View {
        let sections = rows.map { row in (row: row, model: row.isOnline ? workspace.model(for: row.server) : nil) }
        let totals = sections.compactMap { s in s.model?.state.snapshot.map { DockerTotals.of($0, host: s.row.state.overview) } }
        let cores = sections.compactMap { s in s.model?.state.snapshot != nil ? s.row.state.overview?.cores : nil }.reduce(0, +)
        let cpuSum = sections.compactMap { s in s.model?.state.snapshot?.containers.compactMap(\.cpuPercent).reduce(0, +) }.reduce(0, +)
        VStack(alignment: .leading, spacing: 14) {
            TileGrid(count: 5) {
                Headline(title: "Stacks", value: "\(totals.map(\.stacks).reduce(0, +))",
                         detail: "on \(totals.count) server\(totals.count == 1 ? "" : "s")")
                Headline(title: "Containers running", value: "\(totals.map(\.running).reduce(0, +)) / \(totals.map(\.containers).reduce(0, +))",
                         detail: unhealthyText(totals.map(\.unhealthy).reduce(0, +)),
                         detailTint: totals.map(\.unhealthy).reduce(0, +) > 0 ? Theme.danger : Theme.textMuted)
                Headline(title: "Container CPU", value: cores > 0 ? Format.percent(cpuSum / Double(cores)) : "—",
                         detail: "of \(cores) cores", fraction: cores > 0 ? cpuSum / Double(cores) / 100 : nil)
                Headline(title: "Container memory", value: Format.bytes(totals.map(\.memoryBytes).reduce(0, +)),
                         detail: "across every server")
                Headline(title: "Docker disks", value: dockerDiskValue(totals),
                         detail: "Disks holding \(DockerTotals.dataRoot)",
                         fraction: dockerDiskFraction(totals))
            }
            ForEach(sections, id: \.row.id) { section in
                DockerServerSection(row: section.row, model: section.model,
                                    openDocker: { openServer(section.row.server, .docker) },
                                    openStack: { openStack(section.row.server, $0) })
            }
        }
        .modifier(DockerAttachment(rows: rows, workspace: workspace))
    }

    private func unhealthyText(_ n: Int) -> String { n > 0 ? "\(n) unhealthy" : "None unhealthy" }

    private func dockerDiskValue(_ totals: [DockerTotals]) -> String {
        let disks = totals.compactMap(\.dataDisk)
        guard !disks.isEmpty else { return "—" }
        return Format.bytes(disks.map(\.usedBytes).reduce(0, +))
    }

    private func dockerDiskFraction(_ totals: [DockerTotals]) -> Double? {
        let disks = totals.compactMap(\.dataDisk)
        let total = disks.map(\.totalBytes).reduce(0, +)
        return total > 0 ? Double(disks.map(\.usedBytes).reduce(0, +)) / Double(total) : nil
    }
}

/// One server's Docker: its totals, then a tile per stack.
private struct DockerServerSection: View {
    let row: FleetRow
    let model: DockerModel?
    let openDocker: () -> Void
    let openStack: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                StatusDot(status: lightStatus(row), glow: row.isOnline)
                Text(row.server.name).font(.system(size: 15, weight: .semibold))
                if let snapshot = model?.state.snapshot {
                    let t = DockerTotals.of(snapshot, host: row.state.overview)
                    if t.unhealthy > 0 {
                        Text("\(t.unhealthy) unhealthy").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger)
                    }
                    Text(summary(t)).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer()
                Button("Open Docker", action: openDocker)
                    .buttonStyle(.bordered).controlSize(.small).handCursor()
            }
            content
        }
        .padding(.top, 6)
    }

    @ViewBuilder private var content: some View {
        if !row.isOnline {
            Text(offlineNote(row)).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        } else if let model, let snapshot = model.state.snapshot {
            let stacks = model.stacks
            if snapshot.containers.isEmpty, stacks.isEmpty {
                Text("No containers on this server.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(stacks) { stack in
                        AppTile(stack: stack, serverID: row.server.id, host: row.state.overview?.tailscaleIP ?? row.state.overview?.ipAddress) { openStack(stack.id) }
                    }
                }
            }
        } else if let error = model?.state.error {
            Text(DockerAccess.isPermissionProblem(error)
                 ? "Docker needs sudo on this server. Open its Docker screen to unlock it."
                 : error)
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(3)
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading containers…") }
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
    }

    private func summary(_ t: DockerTotals) -> String {
        var parts = ["\(t.running)/\(t.containers) running"]
        if let cpu = t.cpuPercentOfHost { parts.append("CPU \(Format.percent(cpu))") }
        parts.append("RAM \(Format.bytes(t.memoryBytes))" + (t.memoryFractionOfHost.map { " (\(Format.percent($0 * 100)))" } ?? ""))
        if let disk = t.dataDisk { parts.append("disk \(disk.usePercent)% of \(Format.bytes(disk.totalBytes))") }
        return parts.joined(separator: " · ")
    }
}

/// One stack as an app: its icon, state, services, the port its web front end is published on, image and usage.
private struct AppTile: View {
    let stack: DockerStack
    let serverID: String
    /// The address the Mac reaches the server on (its Tailscale IP when it has one), for the web port's link.
    let host: String?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        icon
                        Text(stack.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    Text(services).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(images).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .help("Open \(stack.name) on the Docker screen")
            // The web port is its own link, outside the tile's button, so clicking it opens the site and not the stack.
            HStack(spacing: 10) {
                if let port = stack.mainWebPort {
                    if let url = webURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label(":" + String(port), systemImage: "globe").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.pointer)
                        .help("Open \(url.absoluteString)")
                    } else {
                        Label(":" + String(port), systemImage: "globe").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    }
                } else if !stack.publishedPorts.isEmpty {
                    Text("ports " + stack.publishedPorts.prefix(3).map(String.init).joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                } else {
                    Text("no published ports").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 4)
                Text(usage).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .stroke(stack.unhealthyCount > 0 ? Theme.danger.opacity(0.5) : (hovering ? Theme.textMuted.opacity(0.5) : Theme.border)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open \(stack.name)", action: open)
            ForEach(stack.bookmarkLinks.compactMap { URL(string: $0.href) }, id: \.self) { url in
                Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var icon: some View {
        AppIconView(stack: stack, serverID: serverID, webHost: host, size: 22)
    }

    /// http://<server>:<web port>, when the stack has a web port and the server's address is known.
    private var webURL: URL? {
        guard let port = stack.mainWebPort, let host else { return nil }
        return URL(string: "http://\(host):\(port)")
    }

    private var statusColor: Color {
        if stack.unhealthyCount > 0 { return Theme.danger }
        if stack.containers.isEmpty || stack.runningCount == 0 { return Theme.idle }
        return stack.stoppedCount > 0 ? Theme.warn : Theme.ok
    }

    private var statusText: String {
        if stack.unhealthyCount > 0 { return "\(stack.unhealthyCount) unhealthy" }
        if stack.containers.isEmpty { return "Not started" }
        return "\(stack.runningCount)/\(stack.containers.count) running"
    }

    private var services: String {
        stack.containers.map { $0.service ?? $0.name }.joined(separator: " · ")
    }

    private var images: String {
        let all = Array(Set(stack.containers.map(\.image))).sorted()
        guard let first = all.first else { return "" }
        return all.count > 1 ? "\(first) +\(all.count - 1)" : first
    }

    private var usage: String {
        let cpu = stack.containers.compactMap(\.cpuPercent)
        let mem = stack.containers.compactMap(\.memoryUsedBytes).reduce(0, +)
        guard !cpu.isEmpty else { return "" }
        return "\(Format.percent(cpu.reduce(0, +))) · \(Format.bytes(mem))"
    }
}

// MARK: - Bookmarks

private struct BookmarksPage: View {
    let rows: [FleetRow]
    let workspace: DockerWorkspace
    @State private var search = ""

    var body: some View {
        let needle = search.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search bookmarks on every server", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                        .buttonStyle(.pointer).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).frame(maxWidth: 360).frame(height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            ForEach(rows) { row in
                BookmarkServerSection(row: row, model: row.isOnline ? workspace.model(for: row.server) : nil, needle: needle)
            }
        }
        .modifier(DockerAttachment(rows: rows, workspace: workspace))
    }
}

private struct BookmarkServerSection: View {
    let row: FleetRow
    let model: DockerModel?
    let needle: String

    var body: some View {
        let items = (model?.bookmarkItems ?? []).filter { item in
            needle.isEmpty || [item.title, item.bookmark.href, item.stack.name, item.bookmark.group ?? "", item.bookmark.description ?? ""]
                .contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        // A search that matches nothing on this server hides the server.
        if needle.isEmpty || !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(status: lightStatus(row), glow: row.isOnline)
                    Text(row.server.name).font(.system(size: 15, weight: .semibold))
                    Text("\(items.count) bookmark\(items.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                if !row.isOnline {
                    Text(offlineNote(row)).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                } else if model?.state.snapshot == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading containers…") }
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                } else if items.isEmpty {
                    Text("No bookmarks. Add one from this server's Bookmarks screen.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(groups(items), id: \.name) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(Theme.textMuted).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                                ForEach(group.items) { BookmarkTile(item: $0) }
                            }
                            .padding(.bottom, 6).padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .card()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .onChange(of: items.map(\.bookmark.href), initial: true) { _, hrefs in FaviconStore.shared.ensure(hrefs) }
        }
    }

    /// Homepage groups in alphabetical order, ungrouped ones last as "Other".
    private func groups(_ items: [BookmarkItem]) -> [(name: String, items: [BookmarkItem])] {
        let byGroup = Dictionary(grouping: items) { $0.bookmark.group ?? "" }
        return byGroup.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        .map { (name: $0.isEmpty ? "Other" : $0, items: byGroup[$0] ?? []) }
    }
}

private struct BookmarkTile: View {
    let item: BookmarkItem
    @State private var hovering = false

    var body: some View {
        let url = URL(string: item.bookmark.href)
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            HStack(alignment: .top, spacing: 10) {
                FaviconView(href: item.bookmark.href, size: 26)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).fontWeight(.semibold).lineLimit(1)
                    if let description = item.bookmark.description, !description.isEmpty {
                        Text(description).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(shortAddress(item.bookmark.href)).font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .lineLimit(1).truncationMode(.middle)
                        ScopeTag(href: item.bookmark.href)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(hovering ? Theme.selection.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .onHover { hovering = $0 }
        .help("Open \(item.bookmark.href)")
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.bookmark.href, forType: .string)
            }
        }
    }
}
