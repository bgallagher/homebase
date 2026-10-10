import Foundation

/// Mirrors `AttentionItem` in spec/models.schema.json and the rules in spec/attention-rules.json.
public struct AttentionItem: Sendable, Codable, Equatable, Identifiable {
    public enum Severity: String, Sendable, Codable { case info, warning, critical }

    public var id: String
    public var severity: Severity
    public var message: String
    /// Screen that helps fix it: "docker", "updates", "terminal".
    public var fix: String
}

public enum Attention {
    public static let diskThresholdPercent = 85

    /// Pure function over a snapshot, so it can later run in the app, a relay or an agent.
    public static func evaluate(_ overview: Overview) -> [AttentionItem] {
        var items: [AttentionItem] = []
        for disk in overview.disks where disk.usePercent > diskThresholdPercent {
            items.append(AttentionItem(
                id: "disk_high:\(disk.mount)",
                severity: disk.usePercent >= 95 ? .critical : .warning,
                message: "\(disk.mount) is \(disk.usePercent)% full.",
                fix: "docker"))
        }
        for name in overview.unhealthyContainers {
            items.append(AttentionItem(
                id: "container_unhealthy:\(name)", severity: .warning,
                message: "\(name) is unhealthy.", fix: "docker"))
        }
        if overview.rebootRequired {
            items.append(AttentionItem(
                id: "reboot_required", severity: .warning,
                message: "A reboot is required to finish applying updates.", fix: "updates"))
        }
        return items
    }
}
