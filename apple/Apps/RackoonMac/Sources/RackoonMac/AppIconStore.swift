import AppKit
import Foundation
import RackoonCore
import SwiftUI

/// Logos for Docker apps and their services. The names come from the open dashboard-icons collection
/// (github.com/homarr-labs/dashboard-icons, Apache-2.0, the set Homepage's `homepage.icon` labels use), fetched from the
/// jsDelivr CDN: its name list once a week and each icon the first time it is shown, both cached under
/// Application Support/Rackoon/app-icons. `AppIconGuess` (Core) picks the best guess; the user can choose another icon for
/// any app or service, which is kept here, on this Mac only (nothing is written to the server).
///
/// Only names are sent (which icons are wanted), never anything about the server. Normal certificate checks apply.
@MainActor @Observable
final class AppIconStore {
    static let shared = AppIconStore(directory: Demo.isOn ? Demo.appIcons : nil)
    static let cdn = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@main"

    private(set) var catalog: IconCatalog?
    /// Icon name -> image, for icons on disk or fetched this run.
    private(set) var images: [String: NSImage] = [:]
    private(set) var fetching: Set<String> = []
    /// "<server id>|<stack id>" -> icon name, or "" to show the letter instead of any icon.
    /// "<server id>|<stack id>|<service>" -> icon name, or "" to use the app's icon.
    private(set) var overrides: [String: String] = [:]

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var iconsDirectory: URL { directory.appendingPathComponent("icons", isDirectory: true) }
    @ObservationIgnored private var catalogFile: URL { directory.appendingPathComponent("catalog.json") }
    @ObservationIgnored private var overridesFile: URL { directory.appendingPathComponent("choices.json") }
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTriedAt: Date?
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    private static let catalogMaxAge: TimeInterval = 7 * 24 * 3600
    private static let retryAfter: TimeInterval = 24 * 3600

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rackoon/app-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: catalogFile) { catalog = IconCatalog.parseTree(data) }
        if let data = try? Data(contentsOf: overridesFile), let loaded = try? JSONDecoder().decode([String: String].self, from: data) {
            overrides = loaded.filter { $0.value.isEmpty || IconCatalog.isSafeName($0.value) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: iconsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "png" {
            let name = file.deletingPathExtension().lastPathComponent
            if IconCatalog.isSafeName(name), let image = NSImage(contentsOf: file) { images[name] = image }
        }
    }

    // MARK: choosing

    private func key(_ serverID: String, _ stack: DockerStack, _ service: String? = nil) -> String {
        [serverID, stack.id, service].compactMap { $0 }.joined(separator: "|")
    }

    /// What a service is called in the choices: its compose service, else its container name.
    static func serviceKey(_ container: DockerContainer) -> String { container.service ?? container.name }

    /// The catalog icon the app is drawn with: the user's choice, else the best guess. Nil: no icon (letter or site icon).
    func stackIcon(_ stack: DockerStack, server: String) -> String? {
        if let chosen = overrides[key(server, stack)] { return chosen.isEmpty ? nil : chosen }
        return catalog.flatMap { AppIconGuess.forStack(stack, in: $0) }
    }

    /// The user chose the letter for this app, so no icon is fetched or guessed for it.
    func prefersLetter(_ stack: DockerStack, server: String) -> Bool { overrides[key(server, stack)] == "" }

    /// The service's own icon, or nil to draw it with the app's icon (a part of the app itself, or the user said so).
    func serviceIcon(_ container: DockerContainer, in stack: DockerStack, server: String) -> String? {
        if let chosen = overrides[key(server, stack, Self.serviceKey(container))] { return chosen.isEmpty ? nil : chosen }
        return catalog.flatMap { AppIconGuess.forService(container, in: $0) }
    }

    /// The automatic choice, for the picker's "Automatic" row.
    func guessedStackIcon(_ stack: DockerStack) -> String? { catalog.flatMap { AppIconGuess.forStack(stack, in: $0) } }
    func guessedServiceIcon(_ container: DockerContainer) -> String? { catalog.flatMap { AppIconGuess.forService(container, in: $0) } }

    func isChosen(_ stack: DockerStack, service: DockerContainer? = nil, server: String) -> Bool {
        overrides[key(server, stack, service.map(Self.serviceKey))] != nil
    }

    /// `name`: an icon; "" for the letter (an app) or the app's icon (a service); nil to go back to the automatic choice.
    func choose(_ name: String?, for stack: DockerStack, service: DockerContainer? = nil, server: String) {
        guard name.map({ $0.isEmpty || IconCatalog.isSafeName($0) }) ?? true else { return }
        overrides[key(server, stack, service.map(Self.serviceKey))] = name
        if let data = try? JSONEncoder().encode(overrides) { try? data.write(to: overridesFile, options: .atomic) }
        if let name, !name.isEmpty { ensure([name]) }
    }

    /// A removed server's choices go with it.
    func forget(serverID: String) {
        let before = overrides.count
        overrides = overrides.filter { !$0.key.hasPrefix(serverID + "|") }
        if overrides.count != before, let data = try? JSONEncoder().encode(overrides) { try? data.write(to: overridesFile, options: .atomic) }
    }

    // MARK: fetching

    func image(_ name: String) -> NSImage? { images[name] }

    /// Downloads the list of icon names if there is none yet or it is over a week old (one try a minute at most).
    func ensureCatalog() {
        guard catalogTask == nil else { return }
        let age = (try? catalogFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) }
        guard catalog == nil || (age ?? .infinity) > Self.catalogMaxAge else { return }
        if let last = catalogTriedAt, Date().timeIntervalSince(last) < 60 { return }
        catalogTriedAt = Date()
        let file = catalogFile
        catalogTask = Task { [weak self] in
            let data = await Self.download("\(Self.cdn)/tree.json", limit: 4 * 1024 * 1024)
            if let data, let parsed = IconCatalog.parseTree(data) {
                try? data.write(to: file, options: .atomic)
                self?.catalog = parsed
            }
            self?.catalogTask = nil
        }
    }

    /// Fetches icons not on disk yet. An icon that failed is left alone for a day.
    func ensure(_ names: [String]) {
        for name in names where IconCatalog.isSafeName(name) && images[name] == nil && !fetching.contains(name) {
            if let at = failed[name], Date().timeIntervalSince(at) < Self.retryAfter { continue }
            fetching.insert(name)
            queue.append(name)
        }
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let name = self?.queue.first {
                self?.queue.removeFirst()
                let data = await Self.download("\(Self.cdn)/png/\(name).png", limit: 2 * 1024 * 1024)
                self?.finish(name, data.flatMap(FaviconStore.renderPNG))
            }
            self?.worker = nil
        }
    }

    private func finish(_ name: String, _ png: Data?) {
        fetching.remove(name)
        if let png, let image = NSImage(data: png) {
            try? png.write(to: iconsDirectory.appendingPathComponent(name + ".png"), options: .atomic)
            images[name] = image
        } else {
            failed[name] = Date()
        }
    }

    /// A plain GET with a size cap and no cookies or credentials. Nil on any error, a non-2xx answer or an oversized body.
    nonisolated private static func download(_ address: String, limit: Int) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Rackoon/1.0 (app icons)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= limit else { return nil }
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
            if let name { store.ensure([name]) }
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
        .task(id: name ?? "") { if let name { store.ensure([name]) } }
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

/// Search the icon collection and pick one, or go back to the automatic choice.
struct IconPicker: View {
    let stack: DockerStack
    let container: DockerContainer?
    let serverID: String
    let close: () -> Void
    @State private var query = ""

    private var title: String { container.map(AppIconStore.serviceKey) ?? stack.name }

    var body: some View {
        let store = AppIconStore.shared
        VStack(alignment: .leading, spacing: 12) {
            Text("Icon for \(title)").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search \(store.catalog.map { "\($0.names.count)" } ?? "") icons", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))

            if let catalog = store.catalog {
                let names = query.trimmingCharacters(in: .whitespaces).isEmpty ? suggestions(catalog) : catalog.search(query, limit: 48)
                Text(query.isEmpty ? "SUGGESTED" : "RESULTS").font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
                if names.isEmpty {
                    Text("No icons match.").font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(height: 60)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 5), spacing: 8) {
                            ForEach(names, id: \.self) { name in cell(name) }
                        }
                    }
                    .frame(height: names.count > 10 ? 250 : (names.count > 5 ? 170 : 85))
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading the icon list…") }
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(height: 60)
            }

            Divider()
            HStack(spacing: 8) {
                Button(automaticLabel) { store.choose(nil, for: stack, service: container, server: serverID); close() }
                    .disabled(!store.isChosen(stack, service: container, server: serverID))
                Button(container == nil ? "Use Letter" : "Use App's Icon") {
                    store.choose("", for: stack, service: container, server: serverID); close()
                }
                Spacer()
            }
            .buttonStyle(.bordered).controlSize(.small).handCursor()
            Text("Icons from the dashboard-icons collection. Your choice is kept on this Mac.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
        .padding(14)
        .frame(width: 370)
        .onAppear { store.ensureCatalog() }
    }

    private var automaticLabel: String {
        let store = AppIconStore.shared
        let guess = container.map { store.guessedServiceIcon($0) } ?? store.guessedStackIcon(stack)
        return "Automatic" + (guess.map { " (\($0))" } ?? "")
    }

    /// Guesses for this app or service first, then the icons of the stack's other services.
    private func suggestions(_ catalog: IconCatalog) -> [String] {
        var out: [String] = []
        if let container { out.append(contentsOf: [AppIconGuess.forService(container, in: catalog)].compactMap { $0 }) }
        out.append(contentsOf: [AppIconGuess.forStack(stack, in: catalog)].compactMap { $0 })
        out += stack.containers.compactMap { AppIconGuess.forService($0, in: catalog) }
        out += catalog.search(stack.name, limit: 10)
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private func cell(_ name: String) -> some View {
        let store = AppIconStore.shared
        let current = container.map { store.serviceIcon($0, in: stack, server: serverID) } ?? store.stackIcon(stack, server: serverID)
        return Button { store.choose(name, for: stack, service: container, server: serverID); close() } label: {
            VStack(spacing: 4) {
                ZStack {
                    if let image = store.image(name) {
                        IconImage(image: image, size: 32)
                    } else if store.fetching.contains(name) {
                        ProgressView().controlSize(.small)
                    } else {
                        LetterTile(name: name, size: 32)
                    }
                }
                .frame(width: 32, height: 32)
                Text(name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 64, height: 58)
            .background(current == name ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .help(name)
        .task { store.ensure([name]) }
    }
}
