import Foundation

/// The user's icon choices for Docker apps and services, and how they combine with the automatic icon. Pure: the app
/// keeps it in `AppIconStore` and saves `overrides` as app-icons/choices.json.
///
/// Keys: `<server id>|<stack id>` for an app and `<server id>|<stack id>|<service>` for one service. Values: an icon id
/// (`AppIconRef`, a collection icon or the user's own image), or "" (an app: draw the letter; a service: use the app's icon).
public struct IconChoices: Sendable, Equatable {
    public private(set) var overrides: [String: String]

    /// Drops anything malformed or not choosable (a hand-edited file, a linked `url:` icon), so it never reaches a URL or path.
    public init(_ raw: [String: String] = [:]) {
        overrides = raw.filter { $0.value.isEmpty || (AppIconRef(id: $0.value)?.isChoosable ?? false) }
    }

    public static func key(server: String, stack: DockerStack, service: String? = nil) -> String {
        [server, stack.id, service].compactMap { $0 }.joined(separator: "|")
    }

    /// What a service is called in the choices: its compose service, else its container name.
    public static func serviceKey(_ container: DockerContainer) -> String { container.service ?? container.name }

    /// The icon an app is drawn with: the user's choice, else the automatic one. Nil: no icon (the letter or a site icon).
    /// `failed` says which downloads failed; a dead template URL then falls back to the collection's guess.
    public func stackIcon(_ stack: DockerStack, server: String, catalog: IconCatalog?, failed: (String) -> Bool = { _ in false }) -> String? {
        if let chosen = overrides[Self.key(server: server, stack: stack)] { return chosen.isEmpty ? nil : chosen }
        return Self.automatic(AppIconGuess.iconID(for: stack, in: catalog), failed: failed) {
            catalog.flatMap { AppIconGuess.forStack(stack, in: $0) }
        }
    }

    /// A service's own icon, or nil to draw it with the app's icon (a part of the app, the user said so, or it is the app
    /// itself and the user chose the app's icon).
    public func serviceIcon(_ container: DockerContainer, in stack: DockerStack, server: String, catalog: IconCatalog?,
                            failed: (String) -> Bool = { _ in false }) -> String? {
        if let chosen = overrides[Self.key(server: server, stack: stack, service: Self.serviceKey(container))] {
            return chosen.isEmpty ? nil : chosen
        }
        if overrides[Self.key(server: server, stack: stack)] != nil, Self.isMainService(container, of: stack, in: catalog) { return nil }
        return Self.automatic(AppIconGuess.iconID(for: container, in: catalog), failed: failed) {
            catalog.flatMap { AppIconGuess.forService(container, in: $0) }
        }
    }

    /// The service that IS the app: a standalone container, the only service, or the one whose automatic icon is the
    /// app's. It follows the icon the user chooses for the app instead of keeping its own automatic one.
    public static func isMainService(_ container: DockerContainer, of stack: DockerStack, in catalog: IconCatalog?) -> Bool {
        if stack.isStandalone || stack.containers.count == 1 { return true }
        let own = AppIconGuess.iconID(for: container, in: catalog)
        return own != nil && own == AppIconGuess.iconID(for: stack, in: catalog)
    }

    /// The automatic icon, unless it is a linked (template) icon whose download failed: then `fallback`.
    static func automatic(_ id: String?, failed: (String) -> Bool, fallback: () -> String?) -> String? {
        if let id, case .remote = AppIconRef(id: id), failed(id) { return fallback() }
        return id
    }

    /// The user chose the letter for this app, so no icon is fetched or guessed for it.
    public func prefersLetter(_ stack: DockerStack, server: String) -> Bool {
        overrides[Self.key(server: server, stack: stack)] == ""
    }

    public func isChosen(_ stack: DockerStack, service: DockerContainer? = nil, server: String) -> Bool {
        overrides[Self.key(server: server, stack: stack, service: service.map(Self.serviceKey))] != nil
    }

    /// `id`: an icon; "" for the letter (an app) or the app's icon (a service); nil to go back to the automatic choice.
    /// Returns false (and changes nothing) for an id that may not be saved.
    @discardableResult
    public mutating func choose(_ id: String?, for stack: DockerStack, service: DockerContainer? = nil, server: String) -> Bool {
        guard id.map({ $0.isEmpty || (AppIconRef(id: $0)?.isChoosable ?? false) }) ?? true else { return false }
        overrides[Self.key(server: server, stack: stack, service: service.map(Self.serviceKey))] = id
        return true
    }

    /// A removed server's choices go with it. Returns whether anything changed.
    @discardableResult
    public mutating func forget(serverID: String) -> Bool {
        let before = overrides.count
        overrides = overrides.filter { !$0.key.hasPrefix(serverID + "|") }
        return overrides.count != before
    }

    /// Every choice that used `id` goes back to automatic (the image was deleted). Returns whether anything changed.
    @discardableResult
    public mutating func removeUses(of id: String) -> Bool {
        let before = overrides.count
        overrides = overrides.filter { $0.value != id }
        return overrides.count != before
    }
}

/// Which icons to download, in what order. Pure: `AppIconStore` runs the downloads.
///
/// Newest urgent requests go first (what is on screen or in the picker right now), each icon is fetched once, and one that
/// failed is not asked for again until `retryAfter` has passed.
public struct IconFetchQueue: Sendable, Equatable {
    public static let retryAfter: TimeInterval = 24 * 3600

    public private(set) var waiting: [String] = []
    /// Waiting or downloading.
    public private(set) var fetching: Set<String> = []
    public private(set) var failed: [String: Date] = [:]

    public init() {}

    /// Queues the ids that need a download. `have` says whether an icon is already in memory or on disk. Ids that can't be
    /// downloaded (malformed, or the user's own images) are ignored. An urgent request for a waiting id moves it to the front.
    public mutating func request(_ ids: [String], urgent: Bool = false, now: Date = Date(), have: (String) -> Bool) {
        for id in ids {
            guard AppIconRef(id: id)?.downloadURL != nil, !have(id) else { continue }
            if fetching.contains(id) {
                if urgent, let i = waiting.firstIndex(of: id) { waiting.remove(at: i); waiting.insert(id, at: 0) }
                continue
            }
            if let at = failed[id], now.timeIntervalSince(at) < Self.retryAfter { continue }
            fetching.insert(id)
            if urgent { waiting.insert(id, at: 0) } else { waiting.append(id) }
        }
    }

    /// The next icon to download, or nil when nothing is waiting. It stays in `fetching` until `finish`.
    public mutating func next() -> String? { waiting.isEmpty ? nil : waiting.removeFirst() }

    public mutating func finish(_ id: String, success: Bool, now: Date = Date()) {
        fetching.remove(id)
        if success { failed[id] = nil } else { failed[id] = now }
    }

    public func hasFailed(_ id: String) -> Bool { failed[id] != nil }
}
