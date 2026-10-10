import Foundation

/// A small line diff (longest common subsequence). Used to highlight changed lines in the editor and to show
/// what a save would change in the confirmation dialog. Files here are at most 64 KiB, so O(n*m) is fine.
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
        let n = a.count, m = b.count
        // lcs[i][j] = length of the longest common subsequence of a[i...] and b[j...]
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(Line(kind: .same, text: a[i], oldNumber: i + 1, newNumber: j + 1)); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                out.append(Line(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1)); j += 1
            } else {
                out.append(Line(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil)); i += 1
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
