import Foundation

public enum SyntaxKind: Sendable, Equatable { case key, string, number, keyword, comment, punctuation }

/// A coloured span. `location` and `length` are UTF-16 offsets into the whole text (what NSRange uses).
public struct SyntaxToken: Sendable, Equatable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxKind
}

/// Small line-based tokenizers for compose YAML and `.env` files. They colour; they do not validate (the server does).
public enum SyntaxHighlighter {
    public static func yaml(_ text: String) -> [SyntaxToken] { scan(text, yamlLine) }
    public static func env(_ text: String) -> [SyntaxToken] { scan(text, envLine) }

    private static func scan(_ text: String, _ line: ([UInt16], Int, inout [SyntaxToken]) -> Void) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var offset = 0
        for raw in text.components(separatedBy: "\n") {
            var units = Array(raw.utf16)
            if units.last == 13 { units.removeLast() }   // \r of a CRLF line is not coloured
            line(units, offset, &tokens)
            offset += raw.utf16.count + 1
        }
        return tokens
    }

    private static let space: UInt16 = 32, hash: UInt16 = 35, colon: UInt16 = 58, dash: UInt16 = 45
    private static let dquote: UInt16 = 34, squote: UInt16 = 39, equals: UInt16 = 61

    // MARK: YAML

    private static func yamlLine(_ u: [UInt16], _ base: Int, _ out: inout [SyntaxToken]) {
        let n = u.count
        var i = 0
        while i < n, u[i] == space { i += 1 }
        guard i < n else { return }
        if u[i] == hash { out.append(.init(location: base + i, length: n - i, kind: .comment)); return }
        // list markers: "- ", possibly nested
        while i < n, u[i] == dash, i + 1 == n || u[i + 1] == space {
            out.append(.init(location: base + i, length: 1, kind: .punctuation))
            i += 1
            while i < n, u[i] == space { i += 1 }
        }
        guard i < n else { return }
        // key: text up to a ":" followed by a space or end, outside quotes and before any comment
        var j = i
        var quote: UInt16 = 0
        var valueStart = i
        while j < n {
            let c = u[j]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == dquote || c == squote, j == i { quote = c }
            else if c == hash, j == i || u[j - 1] == space { break }
            else if c == colon, j + 1 == n || u[j + 1] == space {
                if j > i {
                    out.append(.init(location: base + i, length: j - i, kind: .key))
                    out.append(.init(location: base + j, length: 1, kind: .punctuation))
                    valueStart = j + 1
                }
                break
            }
            j += 1
        }
        yamlValue(u, from: valueStart, base, &out)
    }

    private static func yamlValue(_ u: [UInt16], from start: Int, _ base: Int, _ out: inout [SyntaxToken]) {
        let n = u.count
        var i = start
        while i < n {
            let c = u[i]
            if c == space { i += 1; continue }
            if c == hash, i == 0 || u[i - 1] == space { out.append(.init(location: base + i, length: n - i, kind: .comment)); return }
            if c == dquote || c == squote {
                var k = i + 1
                while k < n, u[k] != c { if u[k] == 92, c == dquote { k += 1 }; k += 1 }   // backslash escapes in "..."
                let end = min(n, k + 1)
                out.append(.init(location: base + i, length: end - i, kind: .string))
                i = end
                continue
            }
            var k = i
            while k < n, u[k] != space { k += 1 }
            let word = String(decoding: u[i..<k], as: UTF16.self)
            if let kind = plainKind(word) { out.append(.init(location: base + i, length: k - i, kind: kind)) }
            i = k
        }
    }

    private static func plainKind(_ word: String) -> SyntaxKind? {
        if ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(word.lowercased()) { return .keyword }
        if word.hasPrefix("${") || word.hasPrefix("$") { return .keyword }
        if let first = word.unicodeScalars.first, first.properties.numericType != nil, first.isASCII,
           word.unicodeScalars.allSatisfy({ ($0.isASCII && $0.properties.numericType != nil) || ".:/_-".unicodeScalars.contains($0) }) {
            return .number
        }
        return nil
    }

    // MARK: .env

    private static func envLine(_ u: [UInt16], _ base: Int, _ out: inout [SyntaxToken]) {
        let n = u.count
        var i = 0
        while i < n, u[i] == space { i += 1 }
        guard i < n else { return }
        if u[i] == hash { out.append(.init(location: base + i, length: n - i, kind: .comment)); return }
        if n - i > 7, String(decoding: u[i..<(i + 7)], as: UTF16.self) == "export ", true {
            out.append(.init(location: base + i, length: 6, kind: .punctuation))
            i += 7
            while i < n, u[i] == space { i += 1 }
        }
        guard let eq = u[i...].firstIndex(of: equals) else { return }
        if eq > i { out.append(.init(location: base + i, length: eq - i, kind: .key)) }
        out.append(.init(location: base + eq, length: 1, kind: .punctuation))
        var v = eq + 1
        guard v < n else { return }
        if u[v] == dquote || u[v] == squote {
            let q = u[v]
            var k = v + 1
            while k < n, u[k] != q { k += 1 }
            let end = min(n, k + 1)
            out.append(.init(location: base + v, length: end - v, kind: .string))
            v = end
            while v < n, u[v] == space { v += 1 }
            if v < n, u[v] == hash { out.append(.init(location: base + v, length: n - v, kind: .comment)) }
            return
        }
        var end = n
        var k = v
        while k < n { if u[k] == hash, k > v, u[k - 1] == space { end = k; break }; k += 1 }
        var trimmed = end
        while trimmed > v, u[trimmed - 1] == space { trimmed -= 1 }
        if trimmed > v { out.append(.init(location: base + v, length: trimmed - v, kind: .string)) }
        if end < n { out.append(.init(location: base + end, length: n - end, kind: .comment)) }
    }
}

/// A quick local check of `.env` syntax, so a typo shows immediately without a round trip.
/// The server's `docker compose config` still has the final say.
public enum EnvSyntax {
    /// The variable names a .env text defines (`NAME=value` and `export NAME=value` lines; comments and odd lines skipped).
    public static func names(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    public static func check(_ text: String) -> [ComposeIssue] {
        var issues: [ComposeIssue] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else {
                issues.append(ComposeIssue(severity: .error, line: index + 1, message: "Expected NAME=value"))
                continue
            }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                issues.append(ComposeIssue(severity: .error, line: index + 1, message: "Missing variable name before ="))
            } else if name.contains(" ") || name.contains("\t") {
                issues.append(ComposeIssue(severity: .error, line: index + 1, message: "Variable names cannot contain spaces"))
            } else if !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) || name.first!.isNumber {
                issues.append(ComposeIssue(severity: .error, line: index + 1, message: "Invalid variable name \"\(name)\""))
            }
        }
        return issues
    }
}
