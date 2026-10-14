import AppKit
import RackoonCore
import SwiftUI

/// The tallest card's natural height, so every card can be drawn at the same height.
private struct TileHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What the Docker screen is showing for each server, kept outside the screen so it survives switching to another
/// sidebar item and back (the screen itself is rebuilt each time): the stack page that was open, and an Add container
/// draft in progress.
@MainActor @Observable
final class DockerWorkspace {
    var openStack: [String: String] = [:]
    var drafts: [String: AddContainerModel] = [:]
    /// One Docker model per server, shared by the Docker and Bookmarks screens so both see the same stacks and labels.
    /// Not observed: it is created on first use, possibly while a view is being built.
    @ObservationIgnored private var models: [String: DockerModel] = [:]

    /// A server was removed: stop its polling and drop everything held for it.
    func forget(serverID: String) {
        models[serverID]?.stop()
        models[serverID] = nil
        commands[serverID]?.cancelOutput()
        commands[serverID] = nil
        files[serverID] = nil
        openStack[serverID] = nil
        drafts[serverID] = nil
    }

    /// One Commands-tab model per server (its output and history survive switching screens).
    @ObservationIgnored private var commands: [String: CommandsModel] = [:]

    func commandsModel(for server: Server) -> CommandsModel {
        if let existing = commands[server.id] { return existing }
        let model = CommandsModel(server: server)
        commands[server.id] = model
        return model
    }

    /// One Files-screen model per server (the folders you were in survive switching screens).
    @ObservationIgnored private var files: [String: FilesModel] = [:]

    func filesModel(for server: Server) -> FilesModel {
        if let existing = files[server.id] { return existing }
        let model = FilesModel(server: server)
        files[server.id] = model
        return model
    }

    /// The access key each model was built with: unlocking or locking Docker through sudo changes it, and the model
    /// (which holds its connection) is rebuilt.
    @ObservationIgnored private var modelKeys: [String: String] = [:]

    func model(for server: Server) -> DockerModel {
        let key = DockerElevation.shared.key(server)
        if let existing = models[server.id], modelKeys[server.id] == key { return existing }
        models[server.id]?.stop()
        let model = DockerModel(server: server)
        models[server.id] = model
        modelKeys[server.id] = key
        return model
    }
}

/// Docker: a grid of stack cards, and a detail page for one stack (its containers, actions and logs).
struct DockerScreen: View {
    let server: Server
    /// The terminal theme, so logs match the terminals.
    let theme: TerminalTheme
    /// Opens a shell inside a container (a terminal tab running `docker exec`).
    let openShell: (DockerContainer) -> Void
    let workspace: DockerWorkspace
    private let model: DockerModel
    @State private var tileHeight: CGFloat = 0
    @State private var bookmarking: BookmarkModel?

    private var openStack: String? {
        get { workspace.openStack[server.id] }
        nonmutating set { workspace.openStack[server.id] = newValue }
    }
    private var newStack: AddContainerModel? {
        get { workspace.drafts[server.id] }
        nonmutating set { workspace.drafts[server.id] = newValue }
    }

    init(server: Server, theme: TerminalTheme, workspace: DockerWorkspace, openShell: @escaping (DockerContainer) -> Void) {
        self.server = server
        self.theme = theme
        self.workspace = workspace
        self.openShell = openShell
        model = workspace.model(for: server)
    }

    var body: some View {
        let state = model.state
        let stack = openStack.flatMap { model.stack(named: $0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let stack {
                    StackDetail(stack: stack, server: server, model: model, theme: theme, busy: state.busy,
                                back: { model.closeLogs(); openStack = nil }, openShell: openShell)
                        .id(stack.name)   // one editor (and its drafts) per stack
                } else if let newStack {
                    AddContainerScreen(model: newStack, theme: theme, back: { self.newStack = nil })
                } else {
                    overviewHeader(state.snapshot)
                }
                // On a stack's page the Output tab shows the run; the banner is for the overview.
                if stack == nil, newStack == nil, let working = model.composeWorking { ComposeBanner(text: working) }
                if let error = state.actionError { ErrorBanner(message: error) }
                DockerAccessNotice(server: server, error: state.error)
                if stack == nil, newStack == nil {
                    if let snapshot = state.snapshot {
                        if snapshot.containers.isEmpty, model.createdStacks.isEmpty {
                            Text("No containers on this server.").foregroundStyle(Theme.textMuted)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                            ForEach(model.stacks.filter(\.hasBookmark) + model.stacks.filter { !$0.hasBookmark }) { stack in   // bookmarked first, each part in its usual order
                                StackTile(stack: stack, busy: state.busy, busyStack: state.busyStacks.contains(stack.name), height: tileHeight,
                                          bookmark: model.bookmarkableStacks.contains { $0.name == stack.name } ? { startBookmark(stack) } : nil) {
                                    openStack = stack.name
                                }
                            }
                        }
                        .onPreferenceChange(TileHeightKey.self) { tileHeight = $0 }
                    } else if state.error == nil {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading containers…") }
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .focusedSceneValue(\.screenRefresh, { model.refresh() })
        .focusedSceneValue(\.screenAdd, canAddContainer ? ScreenAdd(title: "Add Container…", run: startNewStack) : nil)
        // Fetch the icon of any bookmarked site that has none yet.
        .onChange(of: model.bookmarkItems.map(\.bookmark.href), initial: true) { _, hrefs in FaviconStore.shared.ensure(hrefs) }
        .onAppear {
            model.attach()
            if let draft = newStack { attach(draft) }   // a draft from before the screen was rebuilt
        }
        .onDisappear {
            model.closeLogs()   // don't keep streaming a log nobody can see
            model.detach()
        }
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
        .sheet(item: Binding(get: { model.deleting }, set: { model.deleting = $0 })) { stack in
            DeleteStackSheet(stack: stack, serverName: server.name, cancel: { model.deleting = nil },
                             run: { removal in model.deleting = nil; model.delete(stack, removal) })
        }
        .sheet(item: $bookmarking) { draft in
            BookmarkSheet(model: draft, cancel: { bookmarking = nil })
        }
        .onChange(of: model.removedStack) { _, removed in
            if let removed, openStack == removed { openStack = nil }   // the stack is gone: back to the overview
        }
    }

    private func startBookmark(_ stack: DockerStack) {
        guard !SafetyStore.shared.readOnly else { return }
        let draft = BookmarkModel(server: server, choices: model.bookmarkableStacks, groups: model.bookmarkGroups, stack: stack)
        let model = model
        draft.attach(blockedReason: { model.composeBlockedReason(for: $0) }, finished: { stack, apply in
            bookmarking = nil
            if apply {
                model.runDirect(.up, on: stack)   // the label shows once the container is recreated; the output is on the stack's page
                openStack = stack.name
            }
        })
        bookmarking = draft
    }

    /// The same conditions as the Add Container button: on the overview, with data, and not read-only.
    private var canAddContainer: Bool {
        openStack == nil && newStack == nil && !SafetyStore.shared.readOnly && model.state.snapshot != nil
    }

    private func startNewStack() {
        let draft = AddContainerModel(server: server, folder: model.suggestedStackFolder)
        attach(draft)
        newStack = draft
    }

    /// Hands this screen's data and its "finished" step to a draft, which outlives the screen.
    private func attach(_ draft: AddContainerModel) {
        let model = model, workspace = workspace, serverID = server.id
        draft.attach(
            stacks: { model.stacks }, containers: { model.state.snapshot?.containers ?? [] },
            blockedReason: { model.composeBlockedReason(for: $0) },
            finished: { result in
                if result.isNew { model.adopt(result.stack) }
                if result.start { model.runDirect(.up, on: result.stack) }   // the output is already showing when the stack's page opens
                workspace.drafts[serverID] = nil
                workspace.openStack[serverID] = result.stack.name
            })
    }

    private func overviewHeader(_ snapshot: DockerSnapshot?) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Docker").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                if let snapshot {
                    let c = snapshot.containers
                    let running = c.filter(\.isRunning).count
                    let unhealthy = c.filter(\.isUnhealthy).count
                    Text("\(snapshot.stacks.filter { !$0.isStandalone }.count) stacks · \(c.count) containers · \(running) running"
                         + (unhealthy > 0 ? ", \(unhealthy) unhealthy" : ""))
                        .font(.system(size: 13)).foregroundStyle(unhealthy > 0 ? Theme.warn : Theme.textMuted)
                }
            }
            Spacer()
            Button(action: model.refresh) {
                if model.refreshing { Label { Text("Refreshing…") } icon: { ProgressView().controlSize(.small) } }
                else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
                .buttonStyle(.bordered).controlSize(.large).handCursor()
            let blocked = SafetyStore.shared.readOnly ? "Read-only mode is on" : nil
            Button(action: startNewStack) { Label("Add Container", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large).handCursor()
                .disabled(blocked != nil || snapshot == nil)
                .help(blocked ?? "Add a container to a new or existing stack on \(server.name)")
        }
    }
}

// MARK: - Overview card

extension DockerStack {
    /// The stack's bookmarks (Homepage labels), first container first.
    var bookmarkLinks: [Bookmark] { containers.compactMap(\.bookmark) }
}

/// A bookmark's address as a short label: the host, plus a path when there is one ("app.example.com/tv").
func shortAddress(_ href: String) -> String {
    guard let url = URL(string: href), let host = url.host else { return href }
    let path = url.path == "/" ? "" : url.path
    return host + (url.port.map { ":\($0)" } ?? "") + path
}

/// The stack's site as a small link that opens in the default browser: on the card (below the containers) and on the
/// stack page. With more than one bookmark it shows the first and says how many more there are.
private struct StackLink: View {
    let links: [Bookmark]
    var font: CGFloat = 12
    var showScope = true

    var body: some View {
        if let first = links.first, Bookmark.isValidURL(first.href), let url = URL(string: first.href) {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: font - 1))
                    Text(shortAddress(first.href)).font(.system(size: font)).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                    if links.count > 1 { Text("+\(links.count - 1)").font(.system(size: font - 1)).foregroundStyle(Theme.textMuted) }
                    if showScope { ScopeTag(href: first.href) }
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .help(links.count > 1 ? links.map(\.href).joined(separator: "\n") : "Open \(first.href)")
            .accessibilityLabel("Open \(shortAddress(first.href))")
        }
    }
}

/// One stack as a card: containers with their CPU and memory, and a memory bar along the bottom.
private struct StackTile: View {
    let stack: DockerStack
    let busy: Set<String>
    let busyStack: Bool
    /// Height every card is drawn at (the tallest one's natural height).
    let height: CGFloat
    /// Bookmark button; nil when the stack can't take one (no containers yet, or not editable).
    let bookmark: (() -> Void)?
    let open: () -> Void
    @State private var hovering = false

    /// The favicon of the stack's first bookmark that has one; nil (nothing shown) until one has been fetched.
    private var faviconHref: String? {
        stack.containers.compactMap { $0.bookmark?.href }.first { FaviconStore.shared.image(for: $0) != nil }
    }

    var body: some View {
        card
            // Siblings of the card's button, not inside it, so a click on an icon never also opens the stack.
            .overlay(alignment: .topLeading) {
                if let faviconHref {
                    FaviconView(href: faviconHref, size: 26).padding(.top, 16).padding(.leading, 18)
                } else {
                    LetterTile(name: stack.name, size: 26).padding(.top, 16).padding(.leading, 18)
                }
            }
            .overlay(alignment: .bottomLeading) {
                StackLink(links: stack.bookmarkLinks, font: 12)
                    .padding(.leading, 18).padding(.trailing, 18).padding(.bottom, 16)
            }
            .overlay(alignment: .topTrailing) {
                if let bookmark {
                    Button(action: bookmark) {
                        Image(systemName: stack.hasBookmark ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13))
                            .foregroundStyle(stack.hasBookmark ? Theme.accent : (hovering ? Theme.textSecondary : Theme.textMuted.opacity(0.6)))
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.pointer)
                    .padding(.top, 12).padding(.trailing, 10)
                    .help(stack.hasBookmark ? "Edit bookmark" : "Add bookmark")
                    .accessibilityLabel(stack.hasBookmark ? "Edit bookmark" : "Add bookmark")
                }
            }
    }

    private var card: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(stack.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(stack.configFileName ?? "").font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 4)
                    if busyStack || stack.containers.contains(where: { busy.contains($0.id) }) {
                        ProgressView().controlSize(.mini)
                    } else {
                        if !status.text.isEmpty { Text(status.text).font(.system(size: 12)).foregroundStyle(status.color) }
                        Circle().fill(status.dot).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
                    }
                }
                .padding(.trailing, bookmark == nil ? 0 : 26)   // room for the bookmark button
                .padding(.leading, 36)   // and for the icon slot (site icon or letter tile)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stack.containers) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(c.service ?? c.name).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(problem(c) ? Theme.danger : Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(usage(c)).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(problem(c) ? Theme.danger : Theme.textMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
                // Room for the site link, which is drawn over it as a sibling of this button (see `body`).
                if !stack.bookmarkLinks.isEmpty { Color.clear.frame(height: 18) }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
            // Natural height, measured before the uniform height is applied (so cards can shrink again too).
            .background(GeometryReader { Color.clear.preference(key: TileHeightKey.self, value: $0.size.height) })
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(unhealthy ? Theme.danger.opacity(0.5) : (hovering ? Theme.textMuted.opacity(0.5) : Theme.border)))
            .overlay(CornerTicks().stroke(Theme.border, lineWidth: 1.5).padding(5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .onHover { hovering = $0 }
        .help("Open \(stack.name)")
    }

    private var unhealthy: Bool { stack.unhealthyCount > 0 }

    private func problem(_ c: DockerContainer) -> Bool { c.isUnhealthy }

    private func usage(_ c: DockerContainer) -> String {
        guard c.isRunning else { return c.state }
        guard let cpu = c.cpuPercent, let mem = c.memoryUsedBytes else { return "—" }
        return "\(String(format: "%.0f", cpu))% · \(Format.bytes(mem))"
    }

    private var status: (text: String, color: Color, dot: Color) {
        if stack.unhealthyCount > 0 { return ("\(stack.unhealthyCount) unhealthy", Theme.danger, Theme.danger) }
        if stack.containers.isEmpty { return ("Not started", Theme.textMuted, Theme.idle) }
        if stack.runningCount == 0 { return ("Stopped", Theme.textMuted, Theme.idle) }
        if stack.stoppedCount > 0 { return ("\(stack.stoppedCount) stopped", Theme.warn, Theme.warn) }
        return ("", Theme.ok, Theme.ok)
    }
}

/// A tinted letter standing in for a site icon, so every card's title starts at the same place.
struct LetterTile: View {
    let name: String
    var size: CGFloat = 26

    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) } % 360) / 360
        Text(String(name.first.map { Character($0.uppercased()) } ?? "?"))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Color(hue: hue, saturation: 0.35, brightness: 0.9))
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.45, brightness: 0.28), in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

/// Where a link works: `local` = no real domain (a bare name like "dockge", `.local`/`.lan`, a private IP), which only
/// resolves from inside your network or tailnet; `tailscale` = a *.ts.net name or 100.64.0.0/10 address; `publicWeb` = a normal domain.
enum LinkScope: CaseIterable {
    case local, tailscale, publicWeb

    init(href: String) {
        guard let host = URL(string: href)?.host?.lowercased() else { self = .publicWeb; return }
        if host.hasSuffix(".ts.net") { self = .tailscale; return }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 100, (64...127).contains(parts[1]) { self = .tailscale; return }
            let privateRange = parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
                || (parts[0] == 172 && (16...31).contains(parts[1]))
            self = privateRange ? .local : .publicWeb
            return
        }
        let localSuffixes = [".local", ".lan", ".home", ".internal", ".home.arpa", ".localdomain"]
        self = !host.contains(".") || localSuffixes.contains(where: host.hasSuffix) ? .local : .publicWeb
    }

    var title: String { switch self { case .local: "Local"; case .tailscale: "Tailscale"; case .publicWeb: "Public" } }
    var hint: String {
        switch self {
        case .local: "Names and addresses that only work from inside your network"
        case .tailscale: "Only reachable on your tailnet"
        case .publicWeb: "Reachable from anywhere"
        }
    }
    var color: Color {
        switch self {
        case .local: Color(red: 0.553, green: 0.706, blue: 0.941)
        case .tailscale: Color(red: 0.435, green: 0.827, blue: 0.659)
        case .publicWeb: Color(red: 0.941, green: 0.635, blue: 0.478)
        }
    }
}

struct ScopeTag: View {
    let href: String
    var body: some View {
        let scope = LinkScope(href: href)
        Text(scope.title).font(.system(size: 10, weight: .medium)).foregroundStyle(scope.color)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(scope.color.opacity(0.14), in: Capsule())
    }
}

/// Four small corner ticks, the card's signature detail from the design.
private struct CornerTicks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n: CGFloat = 6
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            p.move(to: CGPoint(x: x + dx * n, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy * n))
        }
        return p
    }
}

// MARK: - Stack detail

private struct StackDetail: View {
    let stack: DockerStack
    let server: Server
    let model: DockerModel
    let theme: TerminalTheme
    let busy: Set<String>
    let back: () -> Void
    let openShell: (DockerContainer) -> Void
    @State private var editor: StackEditorModel
    @State private var tab: PanelSelection
    @State private var confirmDiscard = false

    init(stack: DockerStack, server: Server, model: DockerModel, theme: TerminalTheme, busy: Set<String>,
         back: @escaping () -> Void, openShell: @escaping (DockerContainer) -> Void) {
        self.stack = stack
        self.server = server
        self.model = model
        self.theme = theme
        self.busy = busy
        self.back = back
        self.openShell = openShell
        // A run that started just before this page opened (a new stack's first deploy) is already showing.
        _tab = State(initialValue: model.output?.scope == stack.name ? .output : .logs)
        _editor = State(initialValue: StackEditorModel(stack: stack, server: server, redeploy: { model.runDirect(.up, on: $0) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
                .onChange(of: model.output?.id) { _, id in
                    // Starting Pull, Update, Restart... on this stack shows its live output.
                    if id != nil, model.output?.scope == stack.name { tab = .output }
                }
            if stack.containers.count == 1, let only = stack.containers.first {
                ContainerStrip(container: only, stack: stack, busy: busy.contains(only.id), model: model, openShell: openShell)
                panel.frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    containers.frame(width: 320)
                    panel.frame(maxWidth: .infinity)
                }
            }
        }
        // The logs follow every container of the stack, merged; follow the new ones when an update or rebuild replaces a
        // container (its id changes) or when the first appears after a deploy.
        .onAppear(perform: openStackLogs)
        .onChange(of: stack.containers.map(\.id)) { _, _ in openStackLogs() }
    }

    private func openStackLogs() {
        model.showLogs(for: stack.containers)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: { if editor.hasUnsavedChanges { confirmDiscard = true } else { back() } }) {
                    Text("Docker").foregroundStyle(Theme.accent)
                }
                .buttonStyle(.pointer)
                .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
                    Button("Discard Changes", role: .destructive) { back() }
                    Button("Keep Editing", role: .cancel) {}
                } message: { Text("Your edits to \(stack.name)'s files have not been saved.") }
                Text("/").foregroundStyle(Theme.textMuted)
                Text(stack.name).foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 13))
            HStack(alignment: .center, spacing: 10) {
                if let icon = stack.bookmarkLinks.map(\.href).first(where: { FaviconStore.shared.image(for: $0) != nil }) {
                    FaviconView(href: icon, size: 30, hideWhenMissing: true)
                }
                Text(stack.name).font(.system(size: 26, weight: .bold)).tracking(-0.4).lineLimit(1)
                // A pill, centred on the lowercase body of the title (its x-height), which is what the eye reads.
                // Centring on the full text box puts it about 2 pt too high, because ascenders pull that centre up.
                Badge(text: summary.text, color: summary.color).offset(y: 2)
                StackLink(links: stack.bookmarkLinks, font: 13).padding(.leading, 6).offset(y: 2)
                Spacer()
                if !stack.isStandalone { actions }
            }
        }
    }

    private var summary: (text: String, color: Color) {
        let n = stack.containers.count
        if stack.unhealthyCount > 0 { return ("\(stack.unhealthyCount) unhealthy", Theme.danger) }
        if n == 0 { return ("Not started", Theme.textMuted) }
        if stack.runningCount == n { return (n == 1 ? "Running" : "All \(n) running", Theme.ok) }
        if stack.runningCount == 0 { return ("Stopped", Theme.textMuted) }
        return ("\(stack.runningCount) of \(n) running", Theme.warn)
    }

    @ViewBuilder private var actions: some View {
        let reason = model.composeBlockedReason(for: stack)
        let working = busy.contains { id in stack.containers.contains { $0.id == id } } || model.composeWorking != nil
        HStack(spacing: 8) {
            if working { ProgressView().controlSize(.small) }
            Button("Pull Images") { model.request(.pull, on: stack) }.handCursor()
            Button("Rebuild") { model.request(.rebuild, on: stack) }.handCursor()
            Button("Restart") { model.request(.restart, on: stack) }.handCursor()
            Menu {
                Button("Update") { model.request(.up, on: stack) }
                Divider()
                Button("Recreate All Containers…", role: .destructive) { model.request(.recreate, on: stack) }
                Button("Delete Stack…", role: .destructive) { model.requestDelete(stack) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).handCursor()
        }
        .buttonStyle(.bordered).controlSize(.large)
        .disabled(reason != nil)
        .help(reason ?? "Actions for the whole \(stack.name) stack")
    }

    // MARK: containers

    private var containers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTAINERS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
            VStack(spacing: 0) {
                ForEach(stack.containers) { c in
                    ContainerCard(container: c, stack: stack, busy: busy.contains(c.id), model: model, openShell: openShell)
                    if c.id != stack.containers.last?.id { Divider().overlay(Theme.border) }
                }
            }
            .card()
        }
    }

    // MARK: right panel

    private var panel: some View {
        StackPanel(stack: stack, model: model, editor: editor, theme: theme, busy: busy, serverName: server.name, tab: $tab)
    }
}

/// One container in the detail list: status dot, name, usage, image, and text actions.
private struct ContainerCard: View {
    let container: DockerContainer
    let stack: DockerStack
    let busy: Bool
    let model: DockerModel
    let openShell: (DockerContainer) -> Void

    var body: some View {
        let showingLogs = model.logFocus == container.source
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(container.service ?? container.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(usage).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
            }
            Text(container.image).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .lineLimit(1).truncationMode(.middle).padding(.top, 4).padding(.leading, 15)
            ContainerActions(container: container, stack: stack, busy: busy, model: model, openShell: openShell)
                .padding(.top, 10).padding(.leading, 15)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(showingLogs ? Theme.accent.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        // Click a container to follow only its logs; click it again for all of them.
        .onTapGesture { model.logFocus = showingLogs ? nil : container.source }
        .help(showingLogs ? "Showing only \(container.source). Click to show all containers." : "Click to show only \(container.source)'s logs")
    }

    private var dot: Color {
        if container.isUnhealthy { return Theme.danger }
        switch container.state {
        case "running": return container.health == "starting" ? Theme.warn : Theme.ok
        case "restarting", "paused": return Theme.warn
        default: return Theme.idle
        }
    }

    private var usage: String {
        guard container.isRunning else { return container.state }
        guard let cpu = container.cpuPercent, let mem = container.memoryUsedBytes else { return "—" }
        return "\(String(format: "%.0f", cpu))% · \(Format.bytes(mem))"
    }
}

/// Shell, Restart and Rebuild as text links, with Stop/Start tucked into a "···" menu (Stop weighs the same as
/// Restart otherwise).
private struct ContainerActions: View {
    let container: DockerContainer
    let stack: DockerStack
    let busy: Bool
    let model: DockerModel
    let openShell: (DockerContainer) -> Void

    var body: some View {
        HStack(spacing: 14) {
            LinkAction(title: "Shell", enabled: container.isRunning) { openShell(container) }
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                LinkAction(title: "Restart", mutates: true) { model.request(.restart, on: container) }
                if model.canRebuild(container, in: stack) {
                    LinkAction(title: "Rebuild", mutates: true) { model.requestRebuild(of: container, in: stack) }
                }
                Menu {
                    if container.isRunning {
                        Button("Stop…", role: .destructive) { model.request(.stop, on: container) }
                    } else {
                        Button("Start") { model.request(.start, on: container) }
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 20) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().handCursor()
                    .disabled(SafetyStore.shared.readOnly)
                    .help(SafetyStore.shared.readOnly ? "Read-only mode is on" : "More actions")
            }
        }
    }
}

/// A single-container stack has nothing to choose, so its container is one strip above the panel instead of a column.
private struct ContainerStrip: View {
    let container: DockerContainer
    let stack: DockerStack
    let busy: Bool
    let model: DockerModel
    let openShell: (DockerContainer) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Circle().fill(container.isUnhealthy ? Theme.danger : (container.isRunning ? Theme.ok : Theme.idle)).frame(width: 7, height: 7)
            Text(container.image).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            if !container.ports.isEmpty {
                Text(container.ports.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: " ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(usage).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textMuted)
            ContainerActions(container: container, stack: stack, busy: busy, model: model, openShell: openShell)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .card()
    }

    private var usage: String {
        guard container.isRunning else { return container.state }
        guard let cpu = container.cpuPercent, let mem = container.memoryUsedBytes else { return "—" }
        return "\(String(format: "%.0f", cpu))% · \(Format.bytes(mem))"
    }
}

/// A small text action under a container. Mutating ones disable themselves in read-only mode.
private struct LinkAction: View {
    let title: String
    var tint: Color = Theme.textSecondary
    var mutates = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        let blocked = (mutates && SafetyStore.shared.readOnly) || !enabled
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .foregroundStyle(tint)
        .disabled(blocked)
        .opacity(blocked ? 0.4 : 1)
        .help(mutates && SafetyStore.shared.readOnly ? "Read-only mode is on" : (!enabled ? "The container is not running" : title))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    /// Changes something on the server, so it is disabled in read-only mode.
    var mutates = false
    let action: () -> Void

    var body: some View {
        let blocked = mutates && SafetyStore.shared.readOnly
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .foregroundStyle(tint)
        .disabled(blocked)
        .opacity(blocked ? 0.4 : 1)
        .help(blocked ? "Read-only mode is on" : help)
    }
}

private struct ComposeBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fontWeight(.medium)
                Text("This can take a few minutes. It keeps running on the server if you leave this screen.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(12).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct LogPanel: View {
    let model: DockerModel
    let stack: DockerStack
    let theme: TerminalTheme
    let busy: Set<String>
    @State private var copied = false
    @State private var levelFilter: LogLevel?
    @State private var search = ""

    private static let levelWord = try! NSRegularExpression(
        pattern: #"(?i)\b(error|err|fatal|panic|critical|warn|warning|info|debug|trace)\b"#)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(model.logsLive ? Theme.ok : Theme.idle).frame(width: 7, height: 7)
                Text(focused?.source ?? (stack.containers.count > 1 ? "All containers" : (stack.containers.first?.source ?? "Logs")))
                    .fontWeight(.semibold).lineLimit(1).layoutPriority(1)
                Text(model.logsLive ? "Live" : "Ended").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                if focused != nil {
                    Button { model.logFocus = nil } label: {
                        HStack(spacing: 4) { Text("Showing one"); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.pointer).help("Show all containers")
                }
                Spacer(minLength: 4)
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy logs",
                           tint: copied ? Theme.ok : Theme.textSecondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                if let focused {
                    if busy.contains(focused.id) {
                        ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    } else {
                        IconButton(symbol: "arrow.clockwise", help: "Restart \(focused.source)", mutates: true) {
                            model.request(.restart, on: focused)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.sidebar)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            filterBar
            if let error = model.logError { ErrorBanner(message: error).padding(12) }
            LogScroll(text: styled, received: model.logReceived)
                .background(Color(nsColor: theme.backgroundRGB.nsColor))
        }
    }

    private var focused: DockerContainer? {
        model.logFocus.flatMap { f in stack.containers.first { $0.source == f } }
    }

    private struct Parsed { let source: String; let line: String; let level: LogLevel? }

    /// The container name colours, in the order the containers appear.
    private static let sourceColors: [Color] = [
        Color(red: 0.553, green: 0.706, blue: 0.941), Color(red: 0.435, green: 0.827, blue: 0.659),
        Color(red: 0.941, green: 0.635, blue: 0.478), Color(red: 0.78, green: 0.65, blue: 0.94),
        Color(red: 0.95, green: 0.78, blue: 0.4), Color(red: 0.5, green: 0.82, blue: 0.85),
    ]

    private var parsed: [Parsed] {
        model.logEntries
            .filter { model.logFocus == nil || $0.source == model.logFocus }
            .map { Parsed(source: $0.source, line: $0.line, level: LogLineParser.level(of: $0.line)) }
    }

    /// Level chips with counts, and a search box.
    private var filterBar: some View {
        let counts = Dictionary(grouping: parsed, by: \.level).mapValues(\.count)
        return HStack(spacing: 6) {
            chip("All", level: nil, count: parsed.count, color: Theme.textPrimary)
            chip("Error", level: .error, count: counts[.error] ?? 0, color: Theme.danger)
            chip("Warn", level: .warn, count: counts[.warn] ?? 0, color: Theme.warn)
            chip("Info", level: .info, count: counts[.info] ?? 0, color: Theme.accent)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                TextField("Search logs", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                        .buttonStyle(.pointer).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).frame(width: 190, height: 24)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private func chip(_ title: String, level: LogLevel?, count: Int, color: Color) -> some View {
        let on = levelFilter == level
        return Button { levelFilter = level } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? color : Theme.textMuted)
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? color : Theme.textSecondary)
            .padding(.horizontal, 9).frame(height: 24)
            .background(on ? color.opacity(0.14) : .clear, in: Capsule())
            .overlay(Capsule().stroke(on ? color.opacity(0.4) : Theme.border))
        }
        .buttonStyle(.pointer)
    }

    /// Only the level word is coloured (error red, warning amber, info blue); timestamps are dimmed and the message
    /// stays neutral, so a real error stands out instead of the whole log being red.
    private var styled: AttributedString {
        let all = parsed
        guard !all.isEmpty else {
            var waiting = AttributedString("Waiting for output…")
            waiting.foregroundColor = Color(nsColor: theme.foregroundRGB.nsColor).opacity(0.5)
            return waiting
        }
        let needle = search.trimmingCharacters(in: .whitespaces)
        let shown = all.filter { entry in
            (levelFilter == nil || entry.level == levelFilter)
                && (needle.isEmpty || entry.line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        guard !shown.isEmpty else {
            var none = AttributedString("No lines match.")
            none.foregroundColor = Color(nsColor: theme.foregroundRGB.nsColor).opacity(0.5)
            return none
        }
        let fg = Color(nsColor: theme.foregroundRGB.nsColor)
        let muted = fg.opacity(0.45)
        var out = AttributedString()
        let names = stack.containers.map(\.source)
        let showNames = names.count > 1 && model.logFocus == nil
        let nameWidth = min(18, names.map(\.count).max() ?? 0)
        for (i, entry) in shown.enumerated() {
            let line = entry.line
            var prefix = AttributedString()
            var text = AttributedString(line)
            if showNames {
                var tag = AttributedString(entry.source.padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  ")
                tag.foregroundColor = Self.sourceColors[(names.firstIndex(of: entry.source) ?? 0) % Self.sourceColors.count]
                tag.font = .system(size: 12, weight: .semibold, design: .monospaced)
                prefix = tag
            }
            text.foregroundColor = entry.level == .debug ? muted : fg.opacity(0.9)
            let split = LogLineParser.timestampLength(in: line)
            if split > 0 {
                text[text.startIndex..<text.index(text.startIndex, offsetByCharacters: split)].foregroundColor = muted
            }
            if let level = entry.level, level != .debug,
               let m = Self.levelWord.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range, in: text) {
                text[r].foregroundColor = level == .error ? Color(nsColor: theme.ansiRGB[9].nsColor)
                    : level == .warn ? Color(nsColor: theme.ansiRGB[11].nsColor) : Color(nsColor: theme.ansiRGB[12].nsColor)
                text[r].font = .system(size: 12, weight: .semibold, design: .monospaced)
            }
            out += prefix
            out += text
            if i < shown.count - 1 { out += AttributedString("\n") }
        }
        return out
    }
}

// MARK: - Scrolling the logs

/// The log text. Follows new lines while you are at the bottom, stops following when you scroll up (so it doesn't move
/// under you while you read), and shows small floating controls to jump to the latest line or back to the top (⌘↓ / ⌘↑).
/// macOS 15 can report the scroll position, which is what makes the pause and the "N new" count possible; macOS 14
/// keeps the plain behaviour with the jump buttons always shown.
private struct LogScroll: View {
    let text: AttributedString
    let received: Int

    var body: some View {
        if #available(macOS 15, *) {
            FollowingLogScroll(text: text, received: received)
        } else {
            SimpleLogScroll(text: text)
        }
    }
}

private struct LogText: View {
    let text: AttributedString
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

@available(macOS 15, *)
private struct FollowingLogScroll: View {
    let text: AttributedString
    let received: Int
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var atTop = false
    /// How many lines had arrived when the user scrolled away, to count the new ones.
    @State private var pausedAt: Int?

    private struct Metrics: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var visible: CGFloat
        var fromBottom: CGFloat { max(0, content - visible - offset) }
    }
    /// Close enough to an edge to count as being at it.
    private static let slack: CGFloat = 24

    var body: some View {
        ScrollView { LogText(text: text) }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.y, content: geometry.contentSize.height, visible: geometry.containerSize.height)
            } action: { old, new in
                let wasAtBottom = old.fromBottom <= Self.slack
                let nowAtBottom = new.fromBottom <= Self.slack
                let userMoved = abs(new.offset - old.offset) > 0.5
                atTop = new.offset <= Self.slack
                if nowAtBottom {
                    atBottom = true
                    pausedAt = nil
                } else if wasAtBottom && !userMoved {
                    // New lines (or a resized window) pushed the end out of view while we were following it: stay with it.
                    position.scrollTo(edge: .bottom)
                } else {
                    if atBottom { pausedAt = received }
                    atBottom = false
                }
            }
            .overlay(alignment: .bottomTrailing) {
                let newLines = pausedAt.map { max(0, received - $0) } ?? 0
                HStack(spacing: 8) {
                    if !atTop {
                        FloatingJump(symbol: "arrow.up.to.line", title: nil, help: "Jump to the first line (⌘↑)", key: .upArrow) {
                            position.scrollTo(edge: .top)
                        }
                    }
                    if !atBottom {
                        FloatingJump(symbol: "arrow.down.to.line", title: newLines > 0 ? "\(newLines) new" : "Latest",
                                     help: "Jump to the latest line and follow new ones (⌘↓)", key: .downArrow, prominent: true) {
                            position.scrollTo(edge: .bottom)
                        }
                    }
                }
                .padding(14)
                .animation(.easeOut(duration: 0.15), value: atTop)
                .animation(.easeOut(duration: 0.15), value: atBottom)
            }
    }
}

private struct SimpleLogScroll: View {
    let text: AttributedString

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    LogText(text: text)
                    Color.clear.frame(height: 0).id("bottom")
                }
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    FloatingJump(symbol: "arrow.up.to.line", title: nil, help: "Jump to the first line (⌘↑)", key: .upArrow) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                    FloatingJump(symbol: "arrow.down.to.line", title: nil, help: "Jump to the latest line (⌘↓)", key: .downArrow) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .padding(14)
            }
        }
    }
}

/// A small capsule button that floats over the logs. `prominent` is the accent-coloured "latest" one.
private struct FloatingJump: View {
    let symbol: String
    let title: String?
    let help: String
    let key: KeyEquivalent
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if let title { Text(title).font(.system(size: 12, weight: .semibold)).monospacedDigit() }
            }
            .padding(.horizontal, title == nil ? 9 : 12).frame(height: 28)
            .foregroundStyle(prominent ? Theme.accentText : Theme.textPrimary)
            .background(prominent ? Theme.accent : Theme.card, in: Capsule())
            .overlay(Capsule().stroke(prominent ? .clear : Theme.border))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.pointer)
        .keyboardShortcut(key, modifiers: .command)
        .help(help)
        .accessibilityLabel(help)
    }
}
