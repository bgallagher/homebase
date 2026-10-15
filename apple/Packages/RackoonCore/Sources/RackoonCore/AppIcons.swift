import Foundation

/// Where an icon comes from, written as one string id so a choice can be saved and an image cached under it:
/// - `jellyfin`: the dashboard-icons collection (github.com/homarr-labs/dashboard-icons, Apache-2.0; what Homepage's
///   `homepage.icon: jellyfin.png` labels name);
/// - `sh:jellyfin`: the selfh.st collection (github.com/selfhst/icons, CC BY 4.0; Homepage's `sh-` icons), used for the
///   names dashboard-icons doesn't have;
/// - `custom:<sha256 hex>`: an image the user picked on this Mac;
/// - `url:<http(s) URL>`: an icon a label points at (Unraid's `net.unraid.docker.icon`), fetched from the Mac.
public enum AppIconRef: Sendable, Equatable, Hashable {
    case dashboard(String)
    case selfhst(String)
    case custom(String)
    case remote(String)

    public static let dashboardCDN = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@main"
    public static let selfhstCDN = "https://cdn.jsdelivr.net/gh/selfhst/icons@main"
    static let selfhstPrefix = "sh:", customPrefix = "custom:", remotePrefix = "url:"

    /// Nil for anything malformed, so a hand-edited choices file can't put an odd name into a download URL or a file path.
    public init?(id: String) {
        if id.hasPrefix(Self.selfhstPrefix) {
            let name = String(id.dropFirst(Self.selfhstPrefix.count))
            guard IconCatalog.isSafeName(name) else { return nil }
            self = .selfhst(name)
        } else if id.hasPrefix(Self.customPrefix) {
            let hex = String(id.dropFirst(Self.customPrefix.count))
            guard (16...64).contains(hex.count), hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            self = .custom(hex)
        } else if id.hasPrefix(Self.remotePrefix) {
            let url = String(id.dropFirst(Self.remotePrefix.count))
            guard Bookmark.isValidURL(url) else { return nil }
            self = .remote(url)
        } else {
            guard IconCatalog.isSafeName(id) else { return nil }
            self = .dashboard(id)
        }
    }

    public var id: String {
        switch self {
        case .dashboard(let name): name
        case .selfhst(let name): Self.selfhstPrefix + name
        case .custom(let hex): Self.customPrefix + hex
        case .remote(let url): Self.remotePrefix + url
        }
    }

    /// Where the image is downloaded from; nil for the user's own images, which only exist on this Mac.
    public var downloadURL: String? {
        switch self {
        case .dashboard(let name): "\(Self.dashboardCDN)/png/\(name).png"
        case .selfhst(let name): "\(Self.selfhstCDN)/png/\(name).png"
        case .custom: nil
        case .remote(let url): url
        }
    }

    /// The name shown under the icon in the picker.
    public var displayName: String {
        switch self {
        case .dashboard(let name), .selfhst(let name): name
        case .custom: "Your image"
        case .remote(let url): URL(string: url)?.host ?? "Linked icon"
        }
    }

    /// A choice the user may save: a collection icon or their own image (a linked icon is only ever automatic).
    public var isChoosable: Bool { if case .remote = self { false } else { true } }

    /// The icon a label URL points at, or nil unless it is a usable http(s) URL.
    public static func remote(url: String) -> AppIconRef? { Bookmark.isValidURL(url) ? .remote(url) : nil }
}

/// The icon names of the collections Rackoon draws from, so Docker apps can be given a best-guess logo. Pure: the app
/// downloads dashboard-icons' `tree.json`, selfh.st's `index.json` and the icons themselves. Names are icon ids
/// (`AppIconRef`): dashboard-icons names as they are, selfh.st names as `sh:<name>`, and only for apps dashboard-icons lacks.
public struct IconCatalog: Sendable, Equatable {
    /// Icon ids, e.g. "jellyfin", "home-assistant", "vaultwarden-light", "sh:2fauth".
    public let names: Set<String>
    /// Name with every `-` removed -> the id, so "homeassistant" or "pihole" find "home-assistant" and "pi-hole".
    private let compact: [String: String]

    public init(names: some Sequence<String>, selfhst: some Sequence<String> = [String]()) {
        let primary = Set(names.map { $0.lowercased() })
        var all = primary
        var compact: [String: String] = [:]
        // Plain names win over their -light/-dark variants, and shorter over longer, so the result never depends on order.
        let order: (String, String) -> Bool = { (Self.isVariant($0) ? 1 : 0, $0.count, $0) < (Self.isVariant($1) ? 1 : 0, $1.count, $1) }
        for name in primary.sorted(by: order) {
            let key = name.replacingOccurrences(of: "-", with: "")
            if compact[key] == nil { compact[key] = name }
        }
        // The second collection only fills gaps: an app dashboard-icons already has keeps that logo.
        for name in Set(selfhst.map { $0.lowercased() }).sorted(by: order) where Self.isSafeName(name) {
            let key = name.replacingOccurrences(of: "-", with: "")
            guard compact[key] == nil, !primary.contains(name) else { continue }
            let id = AppIconRef.selfhst(name).id
            all.insert(id)
            compact[key] = id
        }
        self.names = all
        self.compact = compact
    }

    /// How many icons come from each collection, for the picker's search prompt.
    public var count: Int { names.count }

    /// Reads selfh.st's `index.json` (`[{"Reference": "2fauth", "PNG": "Yes", ...}]`): the names that have a PNG.
    public static func parseSelfhstIndex(_ data: Data) -> [String]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let names = rows.compactMap { row -> String? in
            guard (row["PNG"] as? String)?.lowercased() == "yes", let ref = (row["Reference"] as? String)?.lowercased() else { return nil }
            return isSafeName(ref) ? ref : nil
        }
        return names.isEmpty ? nil : names
    }

    /// Reads the collection's `tree.json` (`{"png": ["jellyfin.png", ...], "svg": [...], ...}`); only PNG names are kept,
    /// because those are what the app downloads. Nil if it isn't that shape.
    public static func parseTree(_ data: Data) -> IconCatalog? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let png = object["png"] as? [String] else { return nil }
        let names = png.compactMap { $0.hasSuffix(".png") ? String($0.dropLast(4)) : nil }.filter(IconCatalog.isSafeName)
        return names.isEmpty ? nil : IconCatalog(names: names)
    }

    /// Names go into a download URL, so only lowercase letters, digits, `-`, `_` and `.` are accepted.
    public static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, !name.hasPrefix(".") else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-_.".contains($0)) }
    }

    static func isVariant(_ name: String) -> Bool { name.hasSuffix("-light") || name.hasSuffix("-dark") }

    /// The icon called `key`, ignoring dashes, preferring the plain icon over a -light/-dark variant.
    public func lookup(_ key: String) -> String? {
        let key = key.lowercased()
        if names.contains(key), !Self.isVariant(key) { return key }
        if let found = compact[key.replacingOccurrences(of: "-", with: "")] { return found }
        if names.contains(key) { return key }
        // Some apps only come as a variant (a light logo for dark backgrounds, or the reverse).
        return [key + "-light", key + "-dark"].first(where: names.contains)
    }

    /// Icons whose name contains every word of `query` (dashes ignored): exact name first, then names starting with it,
    /// then the rest, shorter names first, dashboard-icons before selfh.st. Variants are left out unless asked for.
    public func search(_ query: String, limit: Int = 60) -> [String] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let wantsVariant = words.contains { $0 == "light" || $0 == "dark" }
        let joined = words.joined()
        func bare(_ id: String) -> String { id.hasPrefix(AppIconRef.selfhstPrefix) ? String(id.dropFirst(AppIconRef.selfhstPrefix.count)) : id }
        let hits = names.filter { id in
            let name = bare(id)
            guard wantsVariant || !Self.isVariant(name) else { return false }
            let flat = name.replacingOccurrences(of: "-", with: "")
            return words.allSatisfy { flat.contains($0) }
        }
        func key(_ id: String) -> (Int, Int, Int, String) {
            let flat = bare(id).replacingOccurrences(of: "-", with: "")
            return (flat == joined ? 0 : flat.hasPrefix(joined) ? 1 : 2, flat.count, id.hasPrefix(AppIconRef.selfhstPrefix) ? 1 : 0, id)
        }
        return Array(hits.sorted { key($0) < key($1) }.prefix(limit))
    }
}

/// Best guesses at which catalog icon belongs to a Docker app (a stack) and to each of its services.
///
/// A stack: its own name ("immich", "paperless-ngx"), else the images of its containers, apps before infrastructure, so a
/// stack of `myorg/thing` + `postgres` doesn't end up with the database's logo. A service: its own image, so the `redis` or
/// `postgres` beside an app gets that logo; a service built for the app (`immich-machine-learning`, or an image the catalog
/// doesn't know) gets nil, which the app draws as the stack's icon.
public enum AppIconGuess {
    /// Databases, caches and queues: they sit beside most apps, so they are the stack's icon only when nothing else matches.
    static let infrastructure: Set<String> = ["postgres", "postgresql", "mariadb", "mysql", "redis", "valkey", "mongodb", "memcached",
                                              "rabbitmq", "elasticsearch", "opensearch", "nginx", "caddy", "traefik", "influxdb", "clickhouse"]
    /// Words that name a role, not a product (`vaultwarden/server`, `goauthentik/server`): never matched on their own.
    static let generic: Set<String> = ["server", "app", "web", "api", "db", "database", "worker", "backend", "frontend", "core", "base",
                                       "main", "latest", "docker", "image", "service", "client", "daemon", "agent", "cli", "ui", "www",
                                       "data", "cache", "stack", "default", "standalone", "local", "dev", "prod", "test"]
    /// Image organisations that publish many unrelated apps, so they say nothing about which app this is.
    static let publishers: Set<String> = ["library", "linuxserver", "bitnami", "hotio", "lscr", "jc21", "docker", "mcr", "microsoft", "binhex",
                                          "google", "amazon", "public", "apps", "images", "containers", "selfhosted"]
    /// Products whose catalog icon has another name, or that belong to a bigger product's family.
    static let aliases: [String: String] = [
        "mongo": "mongodb", "postgis": "postgresql", "pgvecto-rs": "postgresql", "pgvector": "postgresql", "timescaledb": "postgresql",
        "node-exporter": "prometheus", "alertmanager": "prometheus", "pushgateway": "prometheus", "promtail": "loki",
        "cloudflared": "cloudflare", "wg-easy": "wireguard", "redis-stack": "redis", "eclipse-mosquitto": "mosquitto",
        "mysql-server": "mysql", "vaultwarden-server": "vaultwarden", "adguardhome": "adguard-home", "pihole": "pi-hole",
        "homeassistant": "home-assistant", "home-assistant-core": "home-assistant", "nextcloud-aio": "nextcloud", "goauthentik": "authentik",
        "plexpass": "plex", "plex-media-server": "plex", "pms-docker": "plex", "all-in-one": "nextcloud",
    ]
    /// First words that name the base image or bundle, not the app: binhex's `arch-sonarr`, Nextcloud's `aio-redis`.
    static let basePrefixes: Set<String> = ["arch", "alpine", "debian", "ubuntu", "aio"]

    /// The stack's icon, or nil when nothing matches.
    public static func forStack(_ stack: DockerStack, in catalog: IconCatalog) -> String? {
        if let icon = labelIcon(stack, in: catalog) { return icon }
        if let byName = match(nameCandidates(stack.name), in: catalog), !infrastructure.contains(byName) { return byName }
        // The container the stack is named after or that has the bookmark first, then the others in the stack's order.
        let ordered = stack.containers.filter { $0.service == stack.name || $0.bookmark != nil }
            + stack.containers.filter { !($0.service == stack.name || $0.bookmark != nil) }
        let matches = ordered.compactMap { forImage($0.image, in: catalog) }
        return matches.first { !infrastructure.contains($0) } ?? match(nameCandidates(stack.name), in: catalog) ?? matches.first
    }

    /// A service's own icon, or nil when it has none of its own (then it is shown with the stack's icon).
    public static func forService(_ container: DockerContainer, in catalog: IconCatalog) -> String? {
        forImage(container.image, in: catalog)
    }

    /// A Homepage `homepage.icon` label naming a catalog icon ("jellyfin.png", "jellyfin.svg" or "jellyfin").
    static func labelIcon(_ stack: DockerStack, in catalog: IconCatalog) -> String? {
        for icon in stack.containers.compactMap({ $0.bookmark?.icon }) {
            var name = icon.lowercased()
            for ext in [".png", ".svg", ".webp"] where name.hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
            if !name.contains("/"), !name.contains(":"), let found = catalog.lookup(name) { return found }
        }
        return nil
    }

    /// The icon an app is drawn with when the user chose none: a Homepage label naming a catalog icon, then the icon URL
    /// Unraid's template set on one of its containers, then the catalog guess. Works without a catalog for the URL.
    public static func iconID(for stack: DockerStack, in catalog: IconCatalog?) -> String? {
        if let catalog, let icon = labelIcon(stack, in: catalog) { return icon }
        let ordered = stack.containers.filter { $0.service == stack.name || $0.bookmark != nil }
            + stack.containers.filter { !($0.service == stack.name || $0.bookmark != nil) }
        if let url = ordered.lazy.compactMap(\.iconURL).first, let ref = AppIconRef.remote(url: url) { return ref.id }
        return catalog.flatMap { forStack(stack, in: $0) }
    }

    /// A service's own icon when the user chose none: its Unraid template icon, then the guess from its image.
    public static func iconID(for container: DockerContainer, in catalog: IconCatalog?) -> String? {
        if let url = container.iconURL, let ref = AppIconRef.remote(url: url) { return ref.id }
        return catalog.flatMap { forService(container, in: $0) }
    }

    public static func forImage(_ image: String, in catalog: IconCatalog) -> String? {
        match(imageCandidates(image), in: catalog)
    }

    static func match(_ candidates: [String], in catalog: IconCatalog) -> String? {
        for candidate in candidates {
            if let found = catalog.lookup(aliases[candidate] ?? candidate) { return found }
        }
        return nil
    }

    /// Keys to try for an image reference, best first: the repository name and its shorter forms, then the organisation's.
    /// `ghcr.io/immich-app/immich-machine-learning:v1` -> immich-machine-learning, immich-machine, immich, immich-app.
    static func imageCandidates(_ image: String) -> [String] {
        var ref = image.lowercased()
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        var parts = ref.split(separator: "/").map(String.init)
        guard var last = parts.popLast() else { return [] }
        if let colon = last.firstIndex(of: ":") { last = String(last[..<colon]) }
        // A first part with a dot or port, or "localhost", is a registry, not an organisation.
        if let first = parts.first, parts.count >= 1, first.contains(".") || first.contains(":") || first == "localhost" { parts.removeFirst() }
        let name = normalize(last)
        // binhex/arch-delugevpn: the app is the part after the base image's name, and the base alone ("arch") is no guess.
        let pieces = name.split(separator: "-").map(String.init)
        var out = pieces.count > 1 && basePrefixes.contains(pieces[0])
            ? shortened(pieces.dropFirst().joined(separator: "-")) + shortened(name).filter { $0 != pieces[0] }
            : shortened(name)
        // delugevpn, qbittorrentvpn: an app bundled with a VPN client is still that app.
        out += out.compactMap { $0.hasSuffix("vpn") && $0.count > 6 ? String($0.dropLast(3)) : nil }
        if let org = parts.last.map(normalize), !publishers.contains(org) { out += shortened(org) }
        return unique(out)
    }

    /// Keys to try for a stack or container name: the name and its shorter forms, without a trailing replica number.
    static func nameCandidates(_ name: String) -> [String] {
        var n = normalize(name)
        while let r = n.range(of: #"-\d+$"#, options: .regularExpression) { n.removeSubrange(r) }
        return unique(shortened(n))
    }

    static func normalize(_ s: String) -> String {
        var out = s.lowercased().map { "_. ".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        for prefix in ["docker-"] where out.hasPrefix(prefix) && out.count > prefix.count { out.removeFirst(prefix.count) }
        for suffix in ["-docker"] where out.hasSuffix(suffix) && out.count > suffix.count { out.removeLast(suffix.count) }
        return out
    }

    /// "immich-machine-learning" -> itself, "immich-machine", "immich". Pieces under 3 letters and role words are dropped.
    static func shortened(_ name: String) -> [String] {
        var parts = name.split(separator: "-").map(String.init)
        var out: [String] = []
        while !parts.isEmpty {
            let key = parts.joined(separator: "-")
            if key.count >= 3, !generic.contains(key) { out.append(key) }
            parts.removeLast()
        }
        return out
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}
