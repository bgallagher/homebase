import Foundation

/// Searching and reordering the saved servers (the sidebar's server menu). The saved order is the order of `servers.json`,
/// which the Go menu's ⌥⌘1–9 and ⌘[ ⌘] follow too.
public enum ServerList {
    /// The servers whose name, host, user or ~/.ssh/config alias contains every word of `query` (ignoring case and
    /// accents), in saved order. An empty query matches everything.
    public static func filter(_ servers: [Server], query: String) -> [Server] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return servers }
        return servers.filter { server in
            let fields = [server.name, server.host, server.user ?? "", server.sshConfigAlias ?? ""]
            return words.allSatisfy { word in
                fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }

    /// `servers` with `id` moved into `target`'s place (what dragging a row over another row does). Unchanged if either
    /// is missing or they are the same.
    public static func moving(_ id: String, onto target: String, in servers: [Server]) -> [Server] {
        guard id != target, let from = servers.firstIndex(where: { $0.id == id }),
              let to = servers.firstIndex(where: { $0.id == target }) else { return servers }
        var out = servers
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }

    /// `servers` with `id` moved `delta` places (negative is up), stopping at either end.
    public static func moving(_ id: String, by delta: Int, in servers: [Server]) -> [Server] {
        guard let from = servers.firstIndex(where: { $0.id == id }) else { return servers }
        let to = min(max(from + delta, 0), servers.count - 1)
        guard to != from else { return servers }
        var out = servers
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }
}

/// Where the expanded server menu goes. Like a macOS pop-up button, it opens over the collapsed card with the selected
/// server's row exactly where the card was, so it reaches up for servers above it and down for those below; it is pushed
/// back inside the window when that would cross an edge, and its list scrolls when the window is too short for it.
public struct ServerMenuLayout: Equatable, Sendable {
    public static let rowHeight = 40.0
    /// From the panel's top edge to the first row: the list's inset. Nothing else sits above the rows, so the list itself
    /// opens over the card.
    public static let header = 4.0
    /// From the last row to the panel's bottom edge: the list's inset (4), a divider (1) and the search and Add row (44).
    public static let footer = 49.0
    /// Closest the panel comes to the window's bottom edge, and to its top unless the caller asks for more room there
    /// (the title bar's traffic lights).
    public static let margin = 8.0

    /// The panel's top edge, in window coordinates (y grows downwards).
    public var top: Double
    /// The visible height of the list of rows; the list scrolls when it holds more.
    public var listHeight: Double
    /// How far the list starts scrolled so the selected row is in view (centred when the list scrolls at all).
    public var scrollOffset: Double

    public var height: Double { Self.header + listHeight + Self.footer }

    public init(top: Double, listHeight: Double, scrollOffset: Double) {
        self.top = top
        self.listHeight = listHeight
        self.scrollOffset = scrollOffset
    }

    /// `rows` servers, the selected one at `selectedIndex` (nil: none, the list opens at its top), the card's vertical
    /// centre at `cardMidY` in a window `windowHeight` tall. The panel's top edge stays at or below `topLimit`.
    public static func place(rows: Int, selectedIndex: Int?, cardMidY: Double, windowHeight: Double,
                             topLimit: Double = margin) -> ServerMenuLayout {
        let content = Double(max(rows, 1)) * rowHeight
        let room = max(rowHeight, windowHeight - topLimit - margin - header - footer)
        let list = min(content, room)
        let index = Double(min(max(selectedIndex ?? 0, 0), max(rows - 1, 0)))
        let rowMid = index * rowHeight + rowHeight / 2
        // Scrolled so the selected row is centred, as far as the list allows (ScrollViewReader's .center anchor).
        let offset = min(max(rowMid - list / 2, 0), content - list)
        let rowCentre = header + rowMid - offset
        let height = header + list + footer
        let lowest = windowHeight - margin - height
        let top = selectedIndex == nil ? cardMidY - header / 2 : cardMidY - rowCentre
        return ServerMenuLayout(top: max(topLimit, min(top, lowest)), listHeight: list, scrollOffset: offset)
    }
}
