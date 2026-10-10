import Foundation

/// Quoting for values we interpolate into commands that run in the server's shell.
public enum ShellQuote {
    /// Single-quotes the value, so the shell treats it as one literal word. Embedded quotes become `'\''`.
    /// Returns nil for values no shell word can safely carry (empty, NUL or newline).
    public static func quote(_ value: String) -> String? {
        guard !value.isEmpty, !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else { return nil }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An absolute path, quoted. Relative paths are refused so a command never depends on the login directory.
    public static func quotePath(_ path: String) -> String? {
        path.hasPrefix("/") ? quote(path) : nil
    }
}

/// Fills `{name}` placeholders in a command template in ONE pass. Inserted values are never rescanned, so a value
/// that happens to contain `{something}` cannot be substituted again (which sequential replacement would do).
enum Template {
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                let name = String(template[template.index(after: i)..<close])
                if let value = values[name] {
                    out += value
                    i = template.index(after: close)
                    continue
                }
            }
            out.append(template[i])
            i = template.index(after: i)
        }
        return out
    }
}
