import HomebaseCore
import SwiftUI

struct OverviewView: View {
    let model: ServerModel
    let host: String

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let o = state.overview {
                    header(o)
                    if !state.attention.isEmpty { AttentionStrip(items: state.attention) }
                    if let error = state.error { ErrorBanner(message: error) }
                    cards(o, cpu: state.cpuPercent)
                } else if let error = state.error {
                    ErrorBanner(message: error)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting to \(host)…") }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.connect(host: host) }
        .onChange(of: host) { _, new in model.connect(host: new) }
    }

    private func header(_ o: Overview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(o.hostname).font(.title.bold())
            Text("\(o.os.prettyName) · up \(Format.uptime(o.uptimeSeconds)) · \(o.cores) cores")
                .foregroundStyle(.secondary)
        }
    }

    private func cards(_ o: Overview, cpu: Double?) -> some View {
        let root = o.disks.first { $0.mount == "/" } ?? o.disks.first
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            StatCard(title: "CPU", value: cpu.map { Format.percent($0) } ?? "…",
                     detail: "load \(Format.load(o.load1)) · \(Format.load(o.load5)) · \(Format.load(o.load15))",
                     fraction: cpu.map { $0 / 100 })
            StatCard(title: "Memory", value: Format.bytes(o.memory.usedBytes),
                     detail: "of \(Format.bytes(o.memory.totalBytes))", fraction: o.memory.usedFraction)
            if let d = root {
                StatCard(title: "Disk \(d.mount)", value: "\(d.usePercent)%",
                         detail: "\(Format.bytes(d.usedBytes)) of \(Format.bytes(d.totalBytes))",
                         fraction: Double(d.usePercent) / 100,
                         tint: d.usePercent > Attention.diskThresholdPercent ? .red : .accentColor)
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    var fraction: Double?
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .bold)).monospacedDigit()
            if let fraction { ProgressView(value: min(max(fraction, 0), 1)).tint(tint) }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AttentionStrip: View {
    let items: [AttentionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            ForEach(items) { item in
                Text(item.message).foregroundStyle(item.severity == .critical ? .red : .primary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
