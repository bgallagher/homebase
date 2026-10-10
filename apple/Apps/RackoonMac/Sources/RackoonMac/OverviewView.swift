import RackoonCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let server: Server
    let openTerminal: () -> Void
    let openScreen: (String) -> Void

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if case .needsTrust = model.phase {
                    Text("Waiting for you to confirm the host key…").foregroundStyle(Theme.textMuted)
                } else if let o = state.overview {
                    header(o, stale: state.isStale ? state.updatedAt : nil)
                    if let flow = model.reboots[server.id] {
                        RebootProgressBanner(flow: flow, name: server.name) { model.dismissReboot(server) }
                    }
                    if !state.attention.isEmpty { AttentionStrip(items: state.attention, open: openScreen) }
                    // While it reboots the failing polls are expected, not news.
                    if let error = state.error, model.reboots[server.id]?.isActive != true { ErrorBanner(message: error) }
                    cards(o, cpu: state.cpuPercent)
                    SystemInfoCard(o: o, polledAt: state.updatedAt)
                } else if let error = state.error {
                    ErrorBanner(message: error)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting to \(server.name)…") }
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
    }

    private func header(_ o: Overview, stale: Date?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(o.hostname).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                Text("\(o.os.prettyName) · up \(Format.uptime(o.uptimeSeconds)) · \(o.cores) cores")
                    .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                if let stale {
                    Text("Showing data from \(stale.formatted(.relative(presentation: .named))) · refreshing…")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
            }
            Spacer()
            Button("Reboot…") { model.requestReboot(server) }
                .buttonStyle(.bordered).controlSize(.large).handCursor()
                .disabled(SafetyStore.shared.readOnly || model.reboots[server.id]?.isActive == true)
                .help(SafetyStore.shared.readOnly ? "Read-only mode is on" : "Reboot \(server.name) and wait for it to come back")
            Button(action: openTerminal) {
                Text("Open Terminal").fontWeight(.semibold)
                    .padding(.horizontal, 16).frame(height: 34)
                    .foregroundStyle(Theme.accentText)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.pointer)
        }
    }

    private func cards(_ o: Overview, cpu: Double?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            StatCard(title: "CPU", trailing: "\(o.cores) cores · load \(Format.load(o.load1))",
                     value: cpu.map { Format.percent($0) } ?? "—",
                     valueTint: cpu == nil ? Theme.textMuted : nil,
                     detail: "load \(Format.load(o.load1)) · \(Format.load(o.load5)) · \(Format.load(o.load15))",
                     fraction: (cpu ?? 0) / 100)  // empty bar until the second reading, so the card keeps its height
            StatCard(title: "Memory", trailing: Format.bytes(o.memory.totalBytes),
                     value: Format.bytes(o.memory.usedBytes), unit: "used",
                     detail: "\(Format.bytes(o.memory.availableBytes)) available",
                     fraction: o.memory.usedFraction)
            ForEach(o.disks, id: \.mount) { d in
                let over = d.usePercent > Attention.diskThresholdPercent
                StatCard(title: "Disk \(d.mount)", trailing: Format.bytes(d.totalBytes),
                         value: "\(d.usePercent)%", valueTint: over ? Theme.danger : nil,
                         detail: "\(Format.bytes(d.usedBytes)) used",
                         fraction: Double(d.usePercent) / 100,
                         tint: over ? Theme.danger : Theme.accent)
            }
        }
    }
}

/// Cockpit-style identity of the server: model, hostname, OS, kernel, machine id, uptime and its own clock.
/// Uptime and the clock tick locally from the last poll, so they move every second without extra requests.
struct SystemInfoCard: View {
    let o: Overview
    let polledAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("System information").fontWeight(.semibold)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, polledAt.map { context.date.timeIntervalSince($0) } ?? 0)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 28, alignment: .top)], alignment: .leading, spacing: 12) {
                    if !o.modelName.isEmpty { row("Model", o.modelName) }
                    row("Hostname", o.hostname)
                    row("Operating system", o.os.prettyName)
                    if !o.kernel.isEmpty { row("Kernel", o.kernel) }
                    if !o.machineID.isEmpty { row("Machine ID", o.machineID, mono: true) }
                    row("Uptime", Format.uptime(o.uptimeSeconds + elapsed))
                    if o.serverTime > 0 { row("Server time", serverTime(o.serverTime + Int64(elapsed))) }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Theme.textMuted).frame(width: 130, alignment: .leading)
            Text(value).font(mono ? .system(size: 12, design: .monospaced) : .body)
                .foregroundStyle(Theme.textPrimary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// The server's clock in the server's own zone, so it reads like `date` there.
    private func serverTime(_ epoch: Int64) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: o.utcOffsetSeconds)
        formatter.dateFormat = "MMM d, yyyy, h:mm:ss a"
        let text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        return o.timeZoneName.isEmpty ? text : "\(text) \(o.timeZoneName)"
    }
}

/// Progress of a reboot started from the app: waiting, back, timed out, or failed.
struct RebootProgressBanner: View {
    let flow: RebootFlow
    let name: String
    let dismiss: () -> Void

    var body: some View {
        switch flow.phase {
        case .requesting:
            box(color: Theme.accent, symbol: nil, title: "Asking \(name) to reboot…", detail: nil, dismissible: false)
        case .waiting(let since):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                box(color: Theme.accent, symbol: nil, title: "Rebooting \(name)…",
                    detail: "Waiting for it to come back · \(Format.duration(context.date.timeIntervalSince(since))) so far", dismissible: false)
            }
        case .back(let after):
            box(color: Theme.ok, symbol: "checkmark.circle.fill", title: "\(name) is back",
                detail: "It restarted and answered again after \(Format.duration(after)).", dismissible: true)
        case .timedOut:
            box(color: Theme.warn, symbol: "exclamationmark.triangle.fill", title: "\(name) has not come back",
                detail: "No answer after 10 minutes. Check the machine or the provider's console.", dismissible: true)
        case .failed(let message):
            box(color: Theme.danger, symbol: "xmark.octagon.fill", title: "Could not reboot \(name)", detail: message, dismissible: true)
        }
    }

    private func box(color: Color, symbol: String?, title: String, detail: String?, dismissible: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color) } else { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            }
            Spacer()
            if dismissible {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.pointer).foregroundStyle(Theme.textMuted).help("Dismiss")
            }
        }
        .padding(12).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StatCard: View {
    let title: String
    var trailing: String = ""
    let value: String
    var unit: String?
    var valueTint: Color?
    let detail: String
    var fraction: Double?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(trailing)
            }
            .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 30, weight: .bold)).tracking(-0.5).monospacedDigit()
                    .foregroundStyle(valueTint ?? Theme.textPrimary)
                if let unit { Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textMuted) }
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                        Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 8).padding(.top, 8)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct AttentionStrip: View {
    let items: [AttentionItem]
    let open: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Theme.warn)
            Text("Needs attention").fontWeight(.semibold).foregroundStyle(Theme.warn)
            FlowChips(items: items, open: open)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.warnBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.warnBorder))
    }
}

private struct FlowChips: View {
    let items: [AttentionItem]
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                // Each chip jumps to the screen that helps fix it, when that screen exists.
                let target = Screen(rawValue: item.fix)?.isAvailable == true
                Button { open(item.fix) } label: {
                    HStack(spacing: 6) {
                        Text(item.message)
                        if target { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(item.severity == .critical ? Theme.danger : Theme.warnText)
                    .background(Theme.warnChip, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.pointer)
                .disabled(!target)
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .foregroundStyle(Theme.danger)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum Format {
    static func uptime(_ seconds: Double) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    /// "45s", "1m 12s", "1h 5m": for short waits, where uptime's minute resolution would read "0m".
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }
    static func load(_ v: Double) -> String { String(format: "%.2f", v) }
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }
}
