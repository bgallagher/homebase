import HomebaseCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let server: Server
    let openTerminal: () -> Void

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if case .needsTrust = model.phase {
                    Text("Waiting for you to confirm the host key…").foregroundStyle(Theme.textMuted)
                } else if let o = state.overview {
                    header(o, stale: state.isStale ? state.updatedAt : nil)
                    if !state.attention.isEmpty { AttentionStrip(items: state.attention) }
                    if let error = state.error { ErrorBanner(message: error) }
                    cards(o, cpu: state.cpuPercent)
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
                     value: cpu.map { Format.percent($0) } ?? "…",
                     detail: "load \(Format.load(o.load1)) · \(Format.load(o.load5)) · \(Format.load(o.load15))",
                     fraction: cpu.map { $0 / 100 })
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

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Theme.warn)
            Text("Needs attention").fontWeight(.semibold).foregroundStyle(Theme.warn)
            FlowChips(items: items)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.warnBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.warnBorder))
    }
}

private struct FlowChips: View {
    let items: [AttentionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                Text(item.message)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(item.severity == .critical ? Theme.danger : Theme.warnText)
                    .background(Theme.warnChip, in: RoundedRectangle(cornerRadius: 7))
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
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }
    static func load(_ v: Double) -> String { String(format: "%.2f", v) }
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }
}
