import RackoonCore
import SwiftUI
import UniformTypeIdentifiers

/// Whether the sidebar's server menu is open, and where its collapsed card is. Shared by the card (in the sidebar) and
/// the panel, which is drawn over the whole window so it can reach past the sidebar's scroll view and close on any click.
@MainActor @Observable
final class ServerSwitcherState {
    /// The window's coordinate space: the card measures itself in it and the panel is placed in it.
    static let space = "rackoon.window"

    private(set) var isOpen = false
    var query = ""
    /// The collapsed card's frame in `space`.
    var cardFrame: CGRect = .zero

    func open() {
        query = ""
        isOpen = true
    }

    func close() { isOpen = false }

    func toggle() { isOpen ? close() : open() }
}

/// A server's light and the words behind it (the light's tooltip).
struct ServerLight {
    var status: ConnectionStatus
    var summary: String
}

/// The collapsed server menu: the selected server's light, name and address. Clicking it opens `ServerSwitcherPanel`
/// over it.
struct ServerSwitcherCard: View {
    let server: Server
    let light: ServerLight
    let switcher: ServerSwitcherState

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.12)) { switcher.toggle() } } label: {
            HStack(spacing: 10) {
                StatusDot(status: light.status, glow: true).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).fontWeight(.semibold).lineLimit(1)
                    Text(server.address).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(switcher.isOpen ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .help("\(light.summary)\nClick to switch server (⌘K)")
        .accessibilityLabel("Server: \(server.name). Switch server")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ServerSwitcherState.space)) } action: { switcher.cardFrame = $0 }
    }
}

extension Server {
    /// What the sidebar shows under the name: `user@host`, plus the port when it is not 22.
    var address: String {
        var text = user.map { "\($0)@\(host)" } ?? host
        if let port, port != 22 { text += ":\(port)" }
        return text
    }
}

/// The open server menu, drawn over the window: every server with its light (drag a row to reorder, right-click for
/// more), then a search field and Add Server. Opens with the selected server's row over the collapsed card
/// (`ServerMenuLayout`), so it reaches up for the servers above and down for those below. Typing filters (the field has
/// focus), ↑ ↓ and Return choose; Esc, a click outside or choosing a server closes it.
struct ServerSwitcherPanel: View {
    let switcher: ServerSwitcherState
    let servers: [Server]
    let selectedID: String?
    let light: (Server) -> ServerLight
    let onSelect: (Server) -> Void
    let onEdit: (Server) -> Void
    let onRemove: (Server) -> Void
    let onReorder: ([Server]) -> Void
    let onAddServer: () -> Void

    @State private var highlighted: String?
    @State private var dragging: String?
    @State private var hovering: String?
    @FocusState private var searchFocused: Bool

    private var visible: [Server] { ServerList.filter(servers, query: switcher.query) }
    private var canReorder: Bool { switcher.query.trimmingCharacters(in: .whitespaces).isEmpty && servers.count > 1 }

    var body: some View {
        GeometryReader { proxy in
            // The card was measured in the window's space; this overlay may start lower (below the title bar's safe area).
            let origin = proxy.frame(in: .named(ServerSwitcherState.space)).origin
            // Kept clear of the title bar's traffic lights.
            let layout = ServerMenuLayout.place(rows: servers.count, selectedIndex: servers.firstIndex { $0.id == selectedID },
                                                cardMidY: switcher.cardFrame.midY - origin.y, windowHeight: proxy.size.height,
                                                topLimit: max(ServerMenuLayout.margin, 34 - origin.y))
            ZStack(alignment: .topLeading) {
                // Any click outside the panel closes it.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return false }   // a drag let go outside
                panel(layout)
                    .frame(width: max(switcher.cardFrame.width, 236))
                    .offset(x: switcher.cardFrame.minX - origin.x, y: layout.top)
            }
        }
    }

    private func panel(_ layout: ServerMenuLayout) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { server in row(server).id(server.id) }
                        if visible.isEmpty {
                            Text("No servers match.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                                .frame(height: ServerMenuLayout.rowHeight)
                        }
                    }
                    .padding(.vertical, ServerMenuLayout.header)
                }
                .scrollIndicators(.automatic)
                // The height stays put while the search narrows the list, so the search field does not jump under the cursor.
                .frame(height: layout.listHeight + 2 * ServerMenuLayout.header, alignment: .top)
                .onAppear {
                    if layout.scrollOffset > 0, let selectedID { reader.scrollTo(selectedID, anchor: .center) }
                }
                .onChange(of: highlighted) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.1)) { reader.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: 6) {
                search
                Button {
                    close()
                    onAddServer()
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Theme.textSecondary)
                        .background(hovering == "+add" ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pointer)
                .onHover { hovering = $0 ? "+add" : (hovering == "+add" ? nil : hovering) }
                .help("Add server… (⇧⌘N)")
                .accessibilityLabel("Add server")
            }
            .frame(height: 32).padding(6)
        }
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .onAppear {
            highlighted = selectedID
            dragging = nil
            searchFocused = true
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
            TextField("Search", text: Bindable(switcher).query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let server = visible.first(where: { $0.id == highlighted }) ?? visible.first { choose(server) } }
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onChange(of: switcher.query) { _, _ in
                    if !visible.contains(where: { $0.id == highlighted }) { highlighted = visible.first?.id }
                }
            if !switcher.query.isEmpty {
                Button { switcher.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.pointer).help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }

    private func row(_ server: Server) -> some View {
        let isSelected = server.id == selectedID
        let isLit = server.id == highlighted || server.id == hovering
        let l = light(server)
        return Button { choose(server) } label: {
            HStack(spacing: 10) {
                StatusDot(status: l.status, glow: isSelected).frame(width: 18).help(l.summary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name).fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
                        .foregroundStyle(Theme.textPrimary)
                    Text(server.address).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                } else if canReorder, server.id == hovering {
                    Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        .help("Drag to reorder")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: ServerMenuLayout.rowHeight)
            .background(isLit ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .opacity(dragging == server.id ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .padding(.horizontal, 4)
        .onHover { inside in
            if inside { hovering = server.id; highlighted = server.id } else if hovering == server.id { hovering = nil }
        }
        .contextMenu {
            Button("Edit Connection…") { close(); onEdit(server) }
            Divider()
            Button("Move Up") { onReorder(ServerList.moving(server.id, by: -1, in: servers)) }
                .disabled(server.id == servers.first?.id)
            Button("Move Down") { onReorder(ServerList.moving(server.id, by: 1, in: servers)) }
                .disabled(server.id == servers.last?.id)
            Divider()
            Button("Remove \(server.name)", role: .destructive) { close(); onRemove(server) }
        }
        .onDrag {
            guard canReorder else { return NSItemProvider() }
            dragging = server.id
            return NSItemProvider(object: server.id as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDrop(target: server.id, servers: servers, dragging: $dragging,
                                                    enabled: canReorder, onReorder: onReorder))
        .accessibilityLabel("\(server.name), \(server.address)\(isSelected ? ", selected" : "")")
    }

    private func step(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : visible.count)
        highlighted = visible[min(max(current + delta, 0), visible.count - 1)].id
    }

    private func choose(_ server: Server) {
        close()
        onSelect(server)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.12)) { switcher.close() }
    }
}

/// Dragging a row over another one moves it into that place straight away, so the list shows the new order while dragging.
private struct ReorderDrop: DropDelegate {
    let target: String
    let servers: [Server]
    @Binding var dragging: String?
    let enabled: Bool
    let onReorder: ([Server]) -> Void

    func validateDrop(info: DropInfo) -> Bool { enabled && dragging != nil }

    func dropEntered(info: DropInfo) {
        guard enabled, let dragging, dragging != target else { return }
        withAnimation(.easeOut(duration: 0.12)) { onReorder(ServerList.moving(dragging, onto: target, in: servers)) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
