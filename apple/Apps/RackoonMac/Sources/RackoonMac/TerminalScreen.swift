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
        // The hidden title bar still reserves ~28 pt of safe area, and the traffic lights sit over the sidebar, so little extra is needed.
        .padding(.leading, 12).padding(.trailing, 12).padding(.top, 6).padding(.bottom, 6)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private func endedOverlay(_ tab: TerminalTab) -> some View {
        VStack(spacing: 10) {
            if let next = tab.reconnecting {
                Text("Connection lost").font(.headline)
                HStack(spacing: 6) {
                    Text("Reconnecting").foregroundStyle(Theme.textMuted)
                    Text(next.at, style: .timer).monospacedDigit().foregroundStyle(Theme.textMuted)
                    Text("(attempt \(next.attempt) of \(next.of))").foregroundStyle(Theme.textMuted)
                }
                .font(.callout)
                HStack {
                    Button("Reconnect Now") { tab.reconnect() }.handCursor().keyboardShortcut(.defaultAction)
                    Button("Cancel") { tab.cancelAutoReconnect() }.handCursor()
                }
            } else {
                Text(tab.exitCode.map { "Session ended (exit \($0))" } ?? "Session ended")
                    .font(.headline)
                Button("Reconnect") { tab.reconnect() }.handCursor().keyboardShortcut(.defaultAction)
            }
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
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tab.isRunning ? Theme.ok : Theme.idle).frame(width: 6, height: 6)
            if editing {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: min(220, max(70, CGFloat(draft.count) * 7.5 + 14)))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false; tab.focusTerminal() }   // Esc: keep the old name
                    .onChange(of: focused) { _, now in if !now, editing { commit() } }
            } else {
                Text(tab.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .help(selected ? "Click to rename" : "")
                    // Only the name starts a rename (on the selected tab); the rest of the tab just selects.
                    .onTapGesture { if selected && !editing { beginEditing() } else if !selected { select() } }
            }
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
        // A click anywhere on an unselected tab selects it.
        .onTapGesture { if !selected { select() } }
        .contextMenu {
            Button("Rename Tab…") { select(); beginEditing() }
            Button("Close Tab", action: close)
        }
        .onHover { hovering = $0 }
    }

    private func beginEditing() {
        draft = tab.title
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        tab.rename(draft)
        tab.focusTerminal()
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
