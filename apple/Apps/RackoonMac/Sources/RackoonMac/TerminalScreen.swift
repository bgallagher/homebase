import RackoonCore
import SwiftTerm
import SwiftUI

struct TerminalScreen: View {
    let store: TerminalStore
    let server: Server

    var body: some View {
        let tabs = store.tabs(for: server)
        let current = store.selectedTab(for: server)
        let background = Color(rgb: AppearanceStore.shared.resolvedTheme.backgroundRGB)
        VStack(spacing: 0) {
            tabStrip(tabs, current: current)
            ZStack {
                background
                if let current {
                    TerminalHost(tab: current).id(current.id)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    if !current.isRunning { endedOverlay(current) }
                } else {
                    VStack(spacing: 12) {
                        Text("No open terminals").foregroundStyle(Theme.textMuted)
                        Button("New Terminal") { store.newTab(for: server) }
                    }
                }
            }
        }
        .onAppear { store.ensureTab(for: server) }
    }

    private func tabStrip(_ tabs: [TerminalTab], current: TerminalTab?) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, selected: tab.id == current?.id,
                          select: { store.select(tab, for: server) },
                          close: { store.close(tab, for: server) })
            }
            Button { store.newTab(for: server) } label: {
                Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .foregroundStyle(Theme.textMuted)
            .help("New tab (⌘T)")
            Spacer()
        }
        .padding(.leading, 12).padding(.trailing, 12).padding(.top, 34).padding(.bottom, 6)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private func endedOverlay(_ tab: TerminalTab) -> some View {
        VStack(spacing: 10) {
            Text(tab.exitCode.map { "Session ended (exit \($0))" } ?? "Session ended")
                .font(.headline)
            Button("Reconnect") { tab.reconnect() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

private struct TabButton: View {
    let tab: TerminalTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tab.isRunning ? Theme.ok : Theme.idle).frame(width: 6, height: 6)
            Text(tab.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

/// Shows a tab's existing terminal view and gives it keyboard focus.
struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = tab.view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
