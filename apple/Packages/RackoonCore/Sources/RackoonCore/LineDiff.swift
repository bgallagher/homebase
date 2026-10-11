import Foundation

/// A line diff on top of the standard library's `CollectionDifference`. Used to highlight changed lines in the editor and to
/// show what a save would change in the confirmation dialog.
public enum LineDiff {
    public enum Kind: Sendable, Equatable { case same, added, removed }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        public var text: String
        /// 1-based line number in the old text (nil for added lines) and in the new text (nil for removed lines).
        public var oldNumber: Int?
        public var newNumber: Int?
    }

    public static func lines(old: String, new: String) -> [Line] {
        let a = split(old), b = split(new)
        // The standard library's diff (Myers' algorithm) finds the minimal removals and insertions.
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                out.append(Line(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil)); i += 1
            } else if j < b.count, inserted.contains(j) {
                out.append(Line(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1)); j += 1
            } else {
                out.append(Line(kind: .same, text: b[j], oldNumber: i + 1, newNumber: j + 1)); i += 1; j += 1
            }
        }
        return out
    }

    /// Lines of the new text that were added or changed (1-based).
    public static func changedLineNumbers(old: String, new: String) -> Set<Int> {
        Set(lines(old: old, new: new).compactMap { $0.kind == .added ? $0.newNumber : nil })
    }

    /// Number of lines added plus lines removed.
    public static func changeCount(old: String, new: String) -> Int {
        lines(old: old, new: new).filter { $0.kind != .same }.count
    }

    /// Changes only, with two lines of context, in a plain +/- form for the confirmation dialog.
    public static func preview(old: String, new: String, context: Int = 2, maxLines: Int = 120) -> String {
        let all = lines(old: old, new: new)
        let changed = all.indices.filter { all[$0].kind != .same }
        guard !changed.isEmpty else { return "No changes." }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(all.count - 1, c + context) { keep.insert(k) } }
        var out: [String] = []
        var last = -2
        for k in keep.sorted() {
            if k != last + 1, last >= 0 { out.append("…") }
            let l = all[k]
            let mark = l.kind == .added ? "+" : (l.kind == .removed ? "-" : " ")
            out.append("\(mark) \(l.text)")
            last = k
        }
        if out.count > maxLines { out = Array(out.prefix(maxLines)) + ["… (\(out.count - maxLines) more lines)"] }
        return out.joined(separator: "\n")
    }

    private static func split(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }   // a trailing newline does not make an extra empty line
        return parts
    }
}
