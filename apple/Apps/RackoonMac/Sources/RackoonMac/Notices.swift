import RackoonCore
import SwiftUI

/// One look for every notice in the app: the "Needs attention" list, errors, the reboot notice and its progress, the
/// connection problem card. A notice is a tinted surface holding rows; a row is an icon, a message and, at the far
/// right, what can be done about it. Change the look here and every notice follows.
@MainActor
enum NoticeTone {
    case warn, danger, ok, info

    var tint: Color {
        switch self {
        case .warn: Theme.warn
        case .danger: Theme.danger
        case .ok: Theme.ok
        case .info: Theme.accent
        }
    }
    var background: Color { self == .warn ? Theme.warnBackground : tint.opacity(0.10) }
    var border: Color { self == .warn ? Theme.warnBorder : tint.opacity(0.35) }
}

extension View {
    /// The shared notice surface: same padding, radius, tint and border everywhere.
    func noticeSurface(_ tone: NoticeTone) -> some View {
        padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.background, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(tone.border))
    }
}

/// An action offered on a notice row (a button that fixes the problem right there).
struct AttentionAction {
    let title: String
    var help: String?
    var enabled = true
    let run: () -> Void
}

/// The one button style for notices: the same size and look as the page header's secondary buttons (Refresh, Reboot…).
struct NoticeButton: View {
    let action: AttentionAction

    var body: some View {
        Button(action.title, action: action.run)
            .buttonStyle(.bordered).controlSize(.large)
            .handCursor()
            .disabled(!action.enabled)
            .help(action.help ?? "")
    }
}

/// A quiet "go to the screen that helps" link at the right of a row.
struct NoticeLink: View {
    let title: String
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
    }
}

/// One line of a notice: severity icon, message (wraps), then the link and the action, right-aligned.
struct NoticeRow: View {
    let icon: String
    let tint: Color
    let message: String
    var detail: String?
    var link: (title: String, run: () -> Void)?
    var action: AttentionAction?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            if let link { NoticeLink(title: link.title, run: link.run) }
            if let action { NoticeButton(action: action) }
        }
        .frame(minHeight: 34)
    }
}

/// "Needs attention": a header band, then a list. The rows are a grid, so the links ("Updates ›") line up in one column
/// and the actions in another whether or not a row has an action; each action sits on the row it belongs to.
struct AttentionStrip: View {
    let items: [AttentionItem]
    let open: (String) -> Void
    var action: (AttentionItem) -> AttentionAction? = { _ in nil }

    var body: some View {
        let actions = items.map(action)
        let hasActions = actions.contains { $0 != nil }
        VStack(alignment: .leading, spacing: 0) {
            // Header band: its own tint and a rule below, so it reads as the title of the list, not an item.
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text("Needs attention").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.warn)
                Text("\(items.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warn)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Theme.warn.opacity(0.18), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Theme.warn.opacity(0.10))
            Rectangle().fill(Theme.warnBorder).frame(height: 1)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Rectangle().fill(Theme.warnBorder.opacity(0.6)).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    let screen = Screen(rawValue: item.fix)
                    GridRow(alignment: .center) {
                        Image(systemName: item.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(item.severity == .critical ? Theme.danger : Theme.warn)
                        Text(item.message).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        Group {
                            if let screen, screen.isAvailable { NoticeLink(title: screen.title) { open(item.fix) } }
                            else { Color.clear.frame(width: 0, height: 0) }
                        }
                        .gridColumnAlignment(.trailing)
                        if hasActions {
                            Group {
                                if let extra = actions[index] { NoticeButton(action: extra) }
                                else { Color.clear.frame(width: 0, height: 0) }
                            }
                            .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .background(Theme.warnBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.warnBorder))
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        NoticeRow(icon: "wifi.exclamationmark", tint: Theme.danger, message: message)
            .noticeSurface(.danger)
    }
}
