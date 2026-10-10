import Foundation

/// Finds a site's icon in its HTML. Pure, so it is tested on fixtures and portable: the app does the fetching and the image
/// decoding; this only says where to look, best candidate first.
public enum FaviconLinks {
    public struct Candidate: Equatable, Sendable {
        public var url: URL
        /// The `rel` tokens, lower-cased (`icon`, `shortcut`, `apple-touch-icon`).
        public var rel: [String]
        public var type: String?
        /// The largest dimension declared in `sizes` (0 when unknown or `any`).
        public var size: Int
    }

    /// The origin of a bookmark URL (`scheme://host[:port]`), the key a favicon is cached under: all bookmarks on one site
    /// share its icon.
    public static func origin(of href: String) -> String? {
        guard Bookmark.isValidURL(href), let url = URL(string: href), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        return url.port.map { $0 == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// `/favicon.ico` on the same origin, the last thing to try.
    public static func defaultIcon(for origin: String) -> URL? { URL(string: origin + "/favicon.ico") }

    /// Icon links in `html`, resolved against `base` (the page's final URL), best first, at most `limit`. Only http(s) and
    /// nothing from `<link>`s that are not icons (`mask-icon` and stylesheets are skipped).
    public static func candidates(in html: String, base: URL, limit: Int = 5) -> [Candidate] {
        var found: [Candidate] = []
        for tag in matches(#"<link\b[^>]*>"#, in: html) {
            let attrs = attributes(of: tag)
            let rel = (attrs["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed"),
                  !rel.contains("mask-icon"), let href = attrs["href"]?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            found.append(Candidate(url: url, rel: rel, type: attrs["type"]?.lowercased(), size: largest(attrs["sizes"])))
        }
        // Best first; Swift's sort is not stable, so ties keep page order through the index.
        let ranked = found.enumerated().sorted { a, b in
            let (sa, sb) = (score(a.element), score(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
        var seen = Set<URL>()
        return Array(ranked.filter { seen.insert($0.url).inserted }.prefix(limit))
    }

    /// apple-touch-icons (usually 180 px PNGs) first, then PNG-like icons, then SVG, then .ico; larger before smaller up to 256.
    static func score(_ c: Candidate) -> Int {
        let path = c.url.path.lowercased()
        let kind: Int
        if c.rel.contains(where: { $0.hasPrefix("apple-touch-icon") }) { kind = 4 }
        else if (c.type ?? "").contains("svg") || path.hasSuffix(".svg") { kind = 2 }
        else if (c.type ?? "").contains("icon") || path.hasSuffix(".ico") { kind = 1 }
        else { kind = 3 }
        return kind * 1000 + min(c.size, 256)
    }

    private static func largest(_ sizes: String?) -> Int {
        (sizes ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { part -> Int? in
            let dims = part.split(separator: "x").compactMap { Int($0) }
            return dims.count == 2 ? max(dims[0], dims[1]) : nil
        }.max() ?? 0
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// `name="value"`, `name='value'` and `name=value` pairs of one tag, names lower-cased.
    static func attributes(of tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z][\w:-]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return [:] }
        var out: [String: String] = [:]
        for m in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let nameRange = Range(m.range(at: 1), in: tag) else { continue }
            let value = [3, 4, 5].compactMap { Range(m.range(at: $0), in: tag).map { String(tag[$0]) } }.first ?? ""
            let name = String(tag[nameRange]).lowercased()
            if out[name] == nil { out[name] = value.replacingOccurrences(of: "&amp;", with: "&") }
        }
        return out
    }
}
