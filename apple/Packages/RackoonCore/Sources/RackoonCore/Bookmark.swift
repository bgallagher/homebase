import Foundation

/// A service's link, stored in the Homepage dashboard's Docker label convention (gethomepage.dev) so the same compose file
/// works with other tools: `homepage.href`, `homepage.name`, `homepage.group`, `homepage.icon`, `homepage.description`.
/// Only `href` is required. Other `homepage.*` labels (widgets, weight...) are neither read nor changed.
public struct Bookmark: Sendable, Codable, Equatable {
    public var href: String
    public var name: String?
    public var group: String?
    public var icon: String?
    public var description: String?

    public init(href: String, name: String? = nil, group: String? = nil, icon: String? = nil, description: String? = nil) {
        self.href = href
        self.name = name
        self.group = group
        self.icon = icon
        self.description = description
    }

    /// The five label keys this convention uses, in the order they are written.
    public static let labelKeys = ["homepage.group", "homepage.name", "homepage.icon", "homepage.href", "homepage.description"]

    /// A bookmark from a container's labels, or nil unless `homepage.href` is a usable http(s) URL.
    public static func from(labels: [String: String]) -> Bookmark? {
        guard let href = labels["homepage.href"]?.trimmingCharacters(in: .whitespaces), isValidURL(href) else { return nil }
        func value(_ key: String) -> String? {
            labels[key].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        return Bookmark(href: href, name: value("homepage.name"), group: value("homepage.group"),
                        icon: value("homepage.icon"), description: value("homepage.description"))
    }

    /// An http or https URL with a host and nothing that could break a label or open something else.
    public static func isValidURL(_ s: String) -> Bool {
        guard s.count <= 2048, !s.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 } ?? false }),
              let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// What to write for each label key: the value, or nil to remove the label. Empty optional fields are removed.
    public var labelChanges: [(key: String, value: String?)] {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        return [("homepage.group", clean(group)), ("homepage.name", clean(name)), ("homepage.icon", clean(icon)),
                ("homepage.href", href.trimmingCharacters(in: .whitespaces)), ("homepage.description", clean(description))]
    }

    /// Removing a bookmark clears all five labels.
    public static var removalChanges: [(key: String, value: String?)] { labelKeys.map { ($0, nil) } }

    /// The label to show: its name, or the service's.
    public func title(fallback: String) -> String { name ?? fallback }
}
