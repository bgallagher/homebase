import AppKit
import RackoonCore
import SwiftUI

/// Every bookmark on the server's containers, grouped by their Homepage `group` label. Add, edit and remove write the
/// labels into the stack's compose.yaml (see `BookmarkModel`).
struct BookmarksScreen: View {
    let server: Server
    let workspace: DockerWorkspace
    /// Shows a stack's page on the Docker screen (after an apply, where its live output is).
    let openStack: (String) -> Void
    @State private var search = ""
    @State private var editing: BookmarkModel?
    @State private var removing: BookmarkModel?
    /// Why a remove couldn't even start (the stack is busy, read-only...). Failures after that are on `removing.notice`.
    @State private var message: String?

    private var model: DockerModel { workspace.model(for: server) }

    var body: some View {
        let all = model.bookmarkItems
        let needle = search.trimmingCharacters(in: .whitespaces)
        let items = needle.isEmpty ? all : all.filter {
            [$0.title, $0.bookmark.href, $0.stack.name, $0.service, $0.bookmark.group ?? ""]
                .contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(count: all.count)
                if let error = model.state.error { ErrorBanner(message: error) }
                if let error = model.state.actionError { ErrorBanner(message: error) }
                if let error = message ?? removing?.notice { ErrorBanner(message: error) }
                if model.state.snapshot == nil, model.state.error == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading containers…") }.foregroundStyle(Theme.textMuted)
                } else if all.isEmpty {
                    emptyState
                } else if items.isEmpty {
                    Text("No bookmarks match “\(needle)”.").foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(sections(items), id: \.scope.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle().fill(section.scope.color).frame(width: 7, height: 7)
                                Text(section.scope.title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textSecondary)
                                Text(section.scope.hint)
                                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                            }
                            VStack(spacing: 0) {
                                ForEach(section.items) { item in
                                    row(item)
                                    if item.id != section.items.last?.id { Divider().overlay(Theme.border) }
                                }
                            }
                            .card()
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .focusedSceneValue(\.screenRefresh, {
            model.refresh()
            FaviconStore.shared.ensure(model.bookmarkItems.map(\.bookmark.href))
        })
        .focusedSceneValue(\.screenAdd, SafetyStore.shared.readOnly || model.bookmarkableStacks.isEmpty
                           ? nil : ScreenAdd(title: "Add Bookmark…", run: add))
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        // A "Read-only mode is on" banner must not outlive the switch that caused it.
        .onChange(of: SafetyStore.shared.readOnly) { _, _ in message = nil }
        // Fetch the icon of any bookmarked site that has none yet (and re-check when a bookmark's address changes).
        .onChange(of: items.map(\.bookmark.href), initial: true) { _, hrefs in FaviconStore.shared.ensure(hrefs) }
        .sheet(item: $editing) { draft in BookmarkSheet(model: draft, cancel: { editing = nil }) }
        .confirmAction(Binding(get: { removing?.pending }, set: { removing?.pending = $0 }))
    }

    // MARK: header and empty state

    private func header(count: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bookmarks").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                Text(count == 0 ? "Links to your services" : "\(count) bookmark\(count == 1 ? "" : "s") · stored as Homepage labels in your compose files")
                    .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if count > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 9).frame(width: 190, height: 30)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
            }
            Button(action: model.refresh) {
                if model.refreshing { Label { Text("Refreshing…") } icon: { ProgressView().controlSize(.small) } }
                else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
                .buttonStyle(.bordered).controlSize(.large).handCursor()
            let blocked = SafetyStore.shared.readOnly ? "Read-only mode is on" : (model.bookmarkableStacks.isEmpty ? "No stack has a container to bookmark yet" : nil)
            Button(action: add) { Label("Add Bookmark", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large).handCursor()
                .disabled(blocked != nil)
                .help(blocked ?? "Bookmark a service")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "bookmark").font(.system(size: 24)).foregroundStyle(Theme.textMuted)
            Text("No bookmarks yet").font(.headline)
            Text("Add a link to a service and it is saved as Homepage labels in that stack's compose.yaml, so it stays with the stack. You can also add them by hand:")
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Text("labels:\n  - homepage.name=AIOStreams\n  - homepage.group=Media\n  - homepage.href=https://aiostreams.example.com/")
                .font(.system(size: 12, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
        .padding(18).frame(maxWidth: 560, alignment: .leading).card()
    }

    // MARK: rows

    private struct Section { let scope: LinkScope; let items: [BookmarkItem] }

    /// Local links first, then Tailscale, then public; each sorted by name.
    private func sections(_ items: [BookmarkItem]) -> [Section] {
        LinkScope.allCases.compactMap { scope in
            let mine = items.filter { LinkScope(href: $0.bookmark.href) == scope }
            guard !mine.isEmpty else { return nil }
            return Section(scope: scope, items: mine.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    private func row(_ item: BookmarkItem) -> some View {
        HStack(spacing: 14) {
            FaviconView(href: item.bookmark.href, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title).fontWeight(.semibold).lineLimit(1)
                    Text("\(item.stack.name) · \(item.service)" + (item.bookmark.group.map { " · \($0)" } ?? "")).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Text(item.bookmark.href).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let description = item.bookmark.description {
                    Text(description).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button { open(item.bookmark.href) } label: {
                Label("Open", systemImage: "arrow.up.forward.square").font(.system(size: 12))
            }
            .buttonStyle(.bordered).controlSize(.small).handCursor().help("Open in your browser")
            Menu {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.bookmark.href, forType: .string)
                }
                Divider()
                Button("Edit…") { edit(item) }.disabled(SafetyStore.shared.readOnly)
                Button("Remove…", role: .destructive) { remove(item) }.disabled(SafetyStore.shared.readOnly)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().handCursor().help("More actions")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: actions

    private func open(_ href: String) {
        guard Bookmark.isValidURL(href), let url = URL(string: href) else { return }
        NSWorkspace.shared.open(url)
    }

    private func add() {
        let draft = BookmarkModel(server: server, choices: model.bookmarkableStacks, groups: model.bookmarkGroups, stack: nil)
        attach(draft)
        editing = draft
    }

    private func edit(_ item: BookmarkItem) {
        message = nil
        removing = nil
        let draft = BookmarkModel(server: server, choices: model.bookmarkableStacks, groups: model.bookmarkGroups,
                                  stack: item.stack, service: item.container.service)
        attach(draft)
        editing = draft
    }

    /// Removing asks for the same confirmation (the compose diff) without the form. Problems show in a banner on this screen.
    private func remove(_ item: BookmarkItem) {
        message = nil
        removing = nil
        if SafetyStore.shared.readOnly { message = "Read-only mode is on"; return }
        if let reason = model.composeBlockedReason(for: item.stack) { message = reason; return }
        let draft = BookmarkModel(server: server, choices: [], groups: [], stack: item.stack, service: item.container.service)
        attach(draft)
        removing = draft
        draft.requestRemoval()
    }

    private func attach(_ draft: BookmarkModel) {
        let model = model, openStack = openStack
        draft.attach(blockedReason: { model.composeBlockedReason(for: $0) }, finished: { stack, apply in
            editing = nil
            removing = nil
            if apply {
                model.runDirect(.up, on: stack)
                openStack(stack.name)
            }
        })
    }
}
