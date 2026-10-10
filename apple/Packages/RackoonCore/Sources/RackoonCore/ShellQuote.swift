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
