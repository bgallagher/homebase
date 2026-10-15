import AppKit
import CryptoKit
import Foundation
import RackoonCore
import SwiftUI
import UniformTypeIdentifiers

/// Logos for Docker apps and their services, from four places (`AppIconRef`):
/// - the dashboard-icons collection (github.com/homarr-labs/dashboard-icons, Apache-2.0, what Homepage's `homepage.icon`
///   labels name) and, for the apps it lacks, the selfh.st collection (github.com/selfhst/icons, CC BY 4.0). Both are fetched
///   from the jsDelivr CDN: their name lists once a week, each icon the first time it is shown;
/// - the icon URL Unraid's Docker template put on a container (`net.unraid.docker.icon`), fetched from the Mac;
/// - images the user picked on this Mac.
/// Everything is cached under Application Support/Rackoon/app-icons. `AppIconGuess` (Core) picks the automatic icon; the
/// user can choose another for any app or service, which is kept here, on this Mac only (nothing is written to the server).
///
/// Only icon names and template URLs are requested, never anything about the server. Normal certificate checks apply.
/// Downloads run several at a time, newest request first, so what is on screen (or in the picker) arrives first, and
/// decoding happens off the main thread.
@MainActor @Observable
final class AppIconStore {
    static let shared = AppIconStore(directory: Demo.isOn ? Demo.appIcons : nil)

    private(set) var catalog: IconCatalog?
    /// Icon id -> image, for icons fetched or imported this run (observed, so views redraw when one arrives).
    private(set) var images: [String: NSImage] = [:]
    /// What to download and what failed (observed: a dead template URL falls back to the collection's guess).
    private(set) var queue = IconFetchQueue()
    var fetching: Set<String> { queue.fetching }
    /// The user's choices, saved as choices.json.
    private(set) var choices = IconChoices()
    /// The user's own images, newest first (ids `custom:<hex>`).
    private(set) var customIcons: [String] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var dashboardNames: [String] = []
    @ObservationIgnored private var selfhstNames: [String] = []
    /// Images read from disk on first use (not observed: reading one must not count as a change during a view update).
    @ObservationIgnored private var diskCache: [String: NSImage] = [:]
    @ObservationIgnored private var catalogTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogTriedAt: Date?
    @ObservationIgnored private var workers = 0
    nonisolated private static let maxWorkers = 6
    private static let catalogMaxAge: TimeInterval = 7 * 24 * 3600
    private static let retryAfter: TimeInterval = 24 * 3600
    /// The largest image file accepted from the user.
    nonisolated static let maxImportBytes = 8 * 1024 * 1024

    private var catalogFile: URL { directory.appendingPathComponent("catalog.json") }
    private var selfhstFile: URL { directory.appendingPathComponent("selfhst-index.json") }
    private var overridesFile: URL { directory.appendingPathComponent("choices.json") }
    private var customDirectory: URL { directory.appendingPathComponent("custom", isDirectory: true) }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rackoon/app-icons", isDirectory: true)
        for folder in ["icons", "icons-selfhst", "icons-linked", "custom"] {
            try? FileManager.default.createDirectory(at: self.directory.appendingPathComponent(folder, isDirectory: true),
                                                     withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: catalogFile), let parsed = IconCatalog.parseTree(data) { dashboardNames = Array(parsed.names) }
        if let data = try? Data(contentsOf: selfhstFile), let parsed = IconCatalog.parseSelfhstIndex(data) { selfhstNames = parsed }
        rebuildCatalog()
        if let data = try? Data(contentsOf: overridesFile), let loaded = try? JSONDecoder().decode([String: String].self, from: data) {
            choices = IconChoices(loaded)
        }
        let custom = (try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        customIcons = custom.filter { $0.pathExtension == "png" }
            .sorted { modified($0) > modified($1) }
            .map { "custom:" + $0.deletingPathExtension().lastPathComponent }
            .filter { AppIconRef(id: $0) != nil }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func rebuildCatalog() {
        guard !dashboardNames.isEmpty || !selfhstNames.isEmpty else { return }
        catalog = IconCatalog(names: dashboardNames, selfhst: selfhstNames)
    }

    /// Where an icon lives on disk. Linked icons are named by a hash of their URL.
    private func file(for ref: AppIconRef) -> URL {
        switch ref {
        case .dashboard(let name): directory.appendingPathComponent("icons/\(name).png")
        case .selfhst(let name): directory.appendingPathComponent("icons-selfhst/\(name).png")
        case .custom(let hex): customDirectory.appendingPathComponent("\(hex).png")
        case .remote(let url): directory.appendingPathComponent("icons-linked/\(Self.sha256(Data(url.utf8)).prefix(32)).png")
        }
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: choosing (the rules are `IconChoices`, Core)

    static func serviceKey(_ container: DockerContainer) -> String { IconChoices.serviceKey(container) }

    func stackIcon(_ stack: DockerStack, server: String) -> String? {
        choices.stackIcon(stack, server: server, catalog: catalog, failed: queue.hasFailed)
    }

    func prefersLetter(_ stack: DockerStack, server: String) -> Bool { choices.prefersLetter(stack, server: server) }

    func serviceIcon(_ container: DockerContainer, in stack: DockerStack, server: String) -> String? {
        choices.serviceIcon(container, in: stack, server: server, catalog: catalog, failed: queue.hasFailed)
    }

    /// The automatic choice, for the picker's "Automatic" row.
    func guessedStackIcon(_ stack: DockerStack) -> String? { AppIconGuess.iconID(for: stack, in: catalog) }
    func guessedServiceIcon(_ container: DockerContainer) -> String? { AppIconGuess.iconID(for: container, in: catalog) }

    func isChosen(_ stack: DockerStack, service: DockerContainer? = nil, server: String) -> Bool {
        choices.isChosen(stack, service: service, server: server)
    }

    /// `id`: an icon; "" for the letter (an app) or the app's icon (a service); nil to go back to the automatic choice.
    func choose(_ id: String?, for stack: DockerStack, service: DockerContainer? = nil, server: String) {
        guard choices.choose(id, for: stack, service: service, server: server) else { return }
        saveChoices()
        if let id, !id.isEmpty { ensure([id], urgent: true) }
    }

    /// A removed server's choices go with it (the user's own images stay, they may be used elsewhere).
    func forget(serverID: String) {
        if choices.forget(serverID: serverID) { saveChoices() }
    }

    private func saveChoices() {
        if let data = try? JSONEncoder().encode(choices.overrides) { try? data.write(to: overridesFile, options: .atomic) }
    }

    // MARK: the user's own images

    /// Reads an image file the user picked or dropped, redraws it as a 256 px PNG and keeps it. Returns its id, or nil
    /// if it isn't an image NSImage can read (or is over 8 MB). The same picture imported twice is stored once.
    func importImage(at url: URL) async -> String? {
        let data: Data? = await Task.detached(priority: .userInitiated) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            guard size <= Self.maxImportBytes, let raw = try? Data(contentsOf: url) else { return nil }
            return FaviconStore.renderPNG(raw, side: 256)
        }.value
        guard let png = data, let image = NSImage(data: png) else { return nil }
        let ref = AppIconRef.custom(String(Self.sha256(png).prefix(32)))
        try? png.write(to: file(for: ref), options: .atomic)
        images[ref.id] = image
        customIcons.removeAll { $0 == ref.id }
        customIcons.insert(ref.id, at: 0)
        return ref.id
    }

    /// Deletes one of the user's images, and every choice that used it (those go back to automatic).
    func deleteCustom(_ id: String) {
        guard case .custom = AppIconRef(id: id) else { return }
        if let ref = AppIconRef(id: id) { try? FileManager.default.removeItem(at: file(for: ref)) }
        customIcons.removeAll { $0 == id }
        images[id] = nil
        diskCache[id] = nil
        if choices.removeUses(of: id) { saveChoices() }
    }

    // MARK: fetching

    /// The image for an icon id: fetched this run, or read from disk the first time it is asked for.
    func image(_ id: String) -> NSImage? {
        if let image = images[id] ?? diskCache[id] { return image }
        guard let ref = AppIconRef(id: id), let image = NSImage(contentsOf: file(for: ref)) else { return nil }
        diskCache[id] = image
        return image
    }

    /// Downloads the name lists if there are none yet or they are over a week old (one try a minute at most).
    func ensureCatalog() {
        guard catalogTasks.isEmpty else { return }
        if let last = catalogTriedAt, Date().timeIntervalSince(last) < 60 { return }
        let lists: [(String, URL, String)] = [
            ("dashboard", catalogFile, "\(AppIconRef.dashboardCDN)/tree.json"),
            ("selfhst", selfhstFile, "\(AppIconRef.selfhstCDN)/index.json"),
        ]
        for (name, file, address) in lists {
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
            let loaded = name == "dashboard" ? !dashboardNames.isEmpty : !selfhstNames.isEmpty
            guard !loaded || (age ?? .infinity) > Self.catalogMaxAge else { continue }
            catalogTriedAt = Date()
            catalogTasks[name] = Task { [weak self] in
                let data = await Self.download(address, limit: 6 * 1024 * 1024)
                // Parsed off the main thread: selfh.st's index is close to a megabyte of JSON.
                let names: [String]? = await Task.detached {
                    guard let data else { return nil }
                    return name == "dashboard" ? IconCatalog.parseTree(data).map { Array($0.names) } : IconCatalog.parseSelfhstIndex(data)
                }.value
                if let data, let names {
                    try? data.write(to: file, options: .atomic)
                    if name == "dashboard" { self?.dashboardNames = names } else { self?.selfhstNames = names }
                    self?.rebuildCatalog()
                }
                self?.catalogTasks[name] = nil
            }
        }
    }

    /// Fetches icons that are not on disk yet (`IconFetchQueue` decides which and in what order). `urgent` (what the picker
    /// or the screen is showing) goes to the front of the queue.
    func ensure(_ ids: [String], urgent: Bool = false) {
        queue.request(ids, urgent: urgent) { id in
            guard let ref = AppIconRef(id: id) else { return true }
            return images[id] != nil || diskCache[id] != nil || FileManager.default.fileExists(atPath: file(for: ref).path)
        }
        while workers < Self.maxWorkers, !queue.waiting.isEmpty {
            workers += 1
            Task { [weak self] in
                while let self, let id = self.queue.next() {
                    // Linked template icons can be any size and format; collection icons are already square PNGs.
                    guard let address = AppIconRef(id: id)?.downloadURL else { self.finish(id, nil); continue }
                    let png = await Self.fetchPNG(address, side: 256)
                    self.finish(id, png)
                }
                self?.workers -= 1
            }
        }
    }

    /// Keeps a downloaded icon (or records the failure).
    func finish(_ id: String, _ png: Data?) {
        if let png, let ref = AppIconRef(id: id), let image = NSImage(data: png) {
            try? png.write(to: file(for: ref), options: .atomic)
            images[id] = image
            queue.finish(id, success: true)
        } else {
            queue.finish(id, success: false)
        }
    }

    /// Download and redraw, both off the main thread.
    nonisolated private static func fetchPNG(_ address: String, side: Int) async -> Data? {
        guard let data = await download(address, limit: 4 * 1024 * 1024) else { return nil }
        return FaviconStore.renderPNG(data, side: side)
    }

    /// One session for every icon request, so connections to the CDN are reused instead of set up for each icon.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = maxWorkers
        return URLSession(configuration: configuration)
    }()

    /// A plain GET with a size cap and no cookies or credentials. Nil on any error, a non-2xx answer or an oversized body.
    nonisolated private static func download(_ address: String, limit: Int) async -> Data? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Rackoon/1.0 (app icons)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= limit,
              let final = response.url?.scheme?.lowercased(), final == "http" || final == "https" else { return nil }
        return data
    }
}

// MARK: - Views

/// An icon image, scaled into a rounded square.
private struct IconImage: View {
    let image: NSImage
    let size: CGFloat
    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

/// A Docker app's icon: the chosen or guessed catalog icon, else its bookmark's site icon, else the site icon of the web page
/// it publishes, else a letter.
struct AppIconView: View {
    let stack: DockerStack
    let serverID: String
    /// The address the Mac reaches the server on, for the site icon of the app's web port.
    var webHost: String?
    var size: CGFloat = 26

    var body: some View {
        let store = AppIconStore.shared
        let name = store.stackIcon(stack, server: serverID)
        let letter = store.prefersLetter(stack, server: serverID)
        let site = letter ? nil : siteHref
        Group {
            if let name, let image = store.image(name) {
                IconImage(image: image, size: size)
            } else if name == nil, let site, let image = FaviconStore.shared.image(for: site) {
                IconImage(image: image, size: size)
            } else {
                LetterTile(name: stack.name, size: size)
            }
        }
        .task(id: "\(name ?? "-")|\(store.catalog != nil)|\(site ?? "")") {
            store.ensureCatalog()
            if let name { store.ensure([name], urgent: true) }
            // Ask the app's own web page only when the catalog has nothing for it (and once the catalog is known).
            else if store.catalog != nil, let web = webHref, !letter { FaviconStore.shared.ensure([web]) }
        }
    }

    /// A bookmark with a fetched icon first, then the web port's page.
    private var siteHref: String? {
        stack.containers.compactMap { $0.bookmark?.href }.first { FaviconStore.shared.image(for: $0) != nil } ?? webHref
    }

    private var webHref: String? {
        guard let host = webHost, let port = stack.mainWebPort else { return nil }
        return "http://\(host):\(port)"
    }
}

/// A service's icon: its own (chosen or guessed), else the app's.
struct ServiceIconView: View {
    let container: DockerContainer
    let stack: DockerStack
    let serverID: String
    var webHost: String?
    var size: CGFloat = 16

    var body: some View {
        let store = AppIconStore.shared
        let name = store.serviceIcon(container, in: stack, server: serverID)
        Group {
            if let name, let image = store.image(name) {
                IconImage(image: image, size: size)
            } else {
                AppIconView(stack: stack, serverID: serverID, webHost: webHost, size: size)
            }
        }
        .task(id: name ?? "") { if let name { store.ensure([name], urgent: true) } }
    }
}

/// An icon that opens the picker when clicked: the app's icon, or one service's when `container` is set.
struct EditableIcon: View {
    let stack: DockerStack
    var container: DockerContainer?
    let serverID: String
    var webHost: String?
    var size: CGFloat = 26
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Group {
                if let container {
                    ServiceIconView(container: container, stack: stack, serverID: serverID, webHost: webHost, size: size)
                } else {
                    AppIconView(stack: stack, serverID: serverID, webHost: webHost, size: size)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .help("Change the icon")
        .accessibilityLabel(container.map { "Icon of \(AppIconStore.serviceKey($0)), change" } ?? "Icon of \(stack.name), change")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            IconPicker(stack: stack, container: container, serverID: serverID, close: { picking = false })
        }
    }
}

/// Search both icon collections and pick one, use an image of your own (Upload Image… or drop a file), or go back to the
/// automatic choice.
struct IconPicker: View {
    let stack: DockerStack
    let container: DockerContainer?
    let serverID: String
    let close: () -> Void
    @State private var query = ""
    @State private var importing = false
    @State private var importProblem: String?
    @State private var dropTargeted = false

    private var title: String { container.map(AppIconStore.serviceKey) ?? stack.name }

    var body: some View {
        let store = AppIconStore.shared
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon for \(title)").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search \(store.catalog.map { "\($0.count.formatted())" } ?? "") icons", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                        .buttonStyle(.pointer).help("Clear")
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if query.isEmpty, !store.customIcons.isEmpty {
                        sectionLabel("YOUR IMAGES")
                        grid(store.customIcons)
                    }
                    if let catalog = store.catalog {
                        let ids = query.trimmingCharacters(in: .whitespaces).isEmpty ? suggestions(catalog) : catalog.search(query, limit: 60)
                        sectionLabel(query.isEmpty ? "SUGGESTED" : "RESULTS")
                        if ids.isEmpty {
                            Text("No icons match. Upload an image of your own below.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(height: 40)
                        } else {
                            grid(ids)
                        }
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading the icon list…") }
                            .font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(height: 60)
                    }
                }
            }
            .frame(height: 260)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(Text("Drop to use this image").fontWeight(.semibold).foregroundStyle(Theme.accent))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await use(url) }
                }
                return true
            }

            if let importProblem {
                Text(importProblem).font(.system(size: 11)).foregroundStyle(Theme.danger)
            }
            Divider()
            HStack(spacing: 8) {
                Button(automaticLabel) { store.choose(nil, for: stack, service: container, server: serverID); close() }
                    .handCursor()
                    .disabled(!store.isChosen(stack, service: container, server: serverID))
                Button(container == nil ? "Use Letter" : "Use App's Icon") {
                    store.choose("", for: stack, service: container, server: serverID); close()
                }
                .handCursor()
                Spacer()
                Button { pickFile() } label: {
                    if importing { ProgressView().controlSize(.mini) } else { Label("Upload Image…", systemImage: "square.and.arrow.up") }
                }
                .handCursor()
                .disabled(importing)
                .help("Use a PNG, JPEG, SVG, WebP or ICNS file from this Mac (or drop one above)")
            }
            .buttonStyle(.bordered).controlSize(.small)
            Text("Icons from dashboard-icons (Apache-2.0) and selfh.st (CC BY 4.0). Your choice and your images stay on this Mac.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { store.ensureCatalog() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
    }

    private func grid(_ ids: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(66), spacing: 6), count: 5), alignment: .leading, spacing: 8) {
            ForEach(ids, id: \.self) { id in cell(id) }
        }
    }

    private var automaticLabel: String {
        let store = AppIconStore.shared
        let guess = container.map { store.guessedServiceIcon($0) } ?? store.guessedStackIcon(stack)
        guard let guess, let ref = AppIconRef(id: guess) else { return "Automatic" }
        if case .remote = ref { return "Automatic (Unraid template)" }
        return "Automatic (\(ref.displayName))"
    }

    /// The automatic icon first (an Unraid template icon included), then guesses for this app and its other services.
    private func suggestions(_ catalog: IconCatalog) -> [String] {
        let store = AppIconStore.shared
        var out: [String] = []
        if let container { out.append(contentsOf: [store.guessedServiceIcon(container)].compactMap { $0 }) }
        out.append(contentsOf: [store.guessedStackIcon(stack)].compactMap { $0 })
        out += stack.containers.compactMap { AppIconGuess.iconID(for: $0, in: catalog) }
        out += catalog.search(stack.name, limit: 10)
        if let container { out += catalog.search(AppIconStore.serviceKey(container), limit: 10) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an icon for \(title)"
        panel.allowedContentTypes = [.png, .jpeg, .svg, .webP, .icns, .tiff, .gif, .bmp, .heic, .ico]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await use(url) }
    }

    private func use(_ url: URL) async {
        importing = true
        importProblem = nil
        let id = await AppIconStore.shared.importImage(at: url)
        importing = false
        guard let id else {
            importProblem = "That file isn't an image Rackoon can read (or it is over 8 MB)."
            return
        }
        AppIconStore.shared.choose(id, for: stack, service: container, server: serverID)
        close()
    }

    private func cell(_ id: String) -> some View {
        let store = AppIconStore.shared
        let current = container.map { store.serviceIcon($0, in: stack, server: serverID) } ?? store.stackIcon(stack, server: serverID)
        let ref = AppIconRef(id: id)
        let isCustom: Bool = if case .custom = ref { true } else { false }
        return Button {
            if ref?.isChoosable == true {
                store.choose(id, for: stack, service: container, server: serverID)
            } else {
                store.choose(nil, for: stack, service: container, server: serverID)   // the template icon is the automatic one
            }
            close()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let image = store.image(id) {
                        IconImage(image: image, size: 34)
                    } else if store.fetching.contains(id) {
                        ProgressView().controlSize(.small)
                    } else {
                        LetterTile(name: ref?.displayName ?? id, size: 34)
                    }
                }
                .frame(width: 34, height: 34)
                Text(ref?.displayName ?? id).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 66, height: 60)
            .background(current == id ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .help(help(ref, id))
        .contextMenu {
            if isCustom { Button("Delete This Image", role: .destructive) { store.deleteCustom(id) } }
        }
        .task(id: id) { store.ensure([id], urgent: true) }
    }

    private func help(_ ref: AppIconRef?, _ id: String) -> String {
        switch ref {
        case .dashboard(let name): "\(name) · dashboard-icons"
        case .selfhst(let name): "\(name) · selfh.st icons"
        case .custom: "Your image (right-click to delete it)"
        case .remote(let url): "From the Unraid template: \(url)"
        case nil: id
        }
    }
}
