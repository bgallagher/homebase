import Foundation

/// Turns streamed log chunks into lines. Chunks arrive split anywhere, and the remote pseudo-terminal
/// ends lines with \r\n, so this joins partial lines, normalises endings and caps memory.
public struct LogBuffer: Sendable, Equatable {
    public private(set) var lines: [String] = []
    /// Every line ever appended, including those trimmed off the front. It only grows, so a view can say "N new lines"
    /// even when the buffer is full and `lines.count` has stopped changing.
    public private(set) var totalAppended = 0
    private var partial = ""
    public let maxLines: Int

    public init(maxLines: Int = 2000) { self.maxLines = maxLines }

    public mutating func append(_ chunk: String) {
        let text = partial + chunk.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var pieces = text.components(separatedBy: "\n")
        partial = pieces.removeLast()
        // ssh prints this itself when the remote command ends; it is not part of the logs.
        let kept = pieces.filter { !($0.hasPrefix("Connection to ") && $0.hasSuffix(" closed.")) }
        lines.append(contentsOf: kept)
        totalAppended += kept.count
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    /// Everything received so far, including a final line that has no newline yet.
    public var text: String { (lines + (partial.isEmpty ? [] : [partial])).joined(separator: "\n") }
}

public enum LogLevel: String, Sendable, Equatable {
    case error, warn, info, debug
}

/// Finds a log line's level and timestamp so the UI can colour it. It only trusts explicit markers
/// (`level=info`, `"level":"warn"`, `[error]`, an upper-case `ERROR`), never prose, so a message that
/// merely mentions "error" is not painted red.
public enum LogLineParser {
    private static func regex(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants; a typo here is a programmer error caught by the unit tests.
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let keyed = regex(#"\blevel["']?\s*[=:]\s*["']?([A-Za-z]+)"#, .caseInsensitive)
    private static let bracketed = regex(#"\[(error|err|fatal|panic|critical|warn|warning|info|debug|trace)\]"#, .caseInsensitive)
    private static let shouting = regex(#"\b(ERROR|ERR|FATAL|PANIC|CRITICAL|WARN|WARNING|INFO|DEBUG|TRACE)\b"#)
    private static let leadingTimestamp = regex(
        #"^\s*(\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(\.\d+)?)"#)

    static func map(_ word: String) -> LogLevel? {
        switch word.lowercased() {
        case "error", "err", "fatal", "panic", "critical": .error
        case "warn", "warning": .warn
        case "info": .info
        case "debug", "trace": .debug
        default: nil
        }
    }

    public static func level(of line: String) -> LogLevel? {
        let range = NSRange(line.startIndex..., in: line)
        for re in [keyed, bracketed, shouting] {
            if let m = re.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line),
               let level = map(String(line[r])) {
                return level
            }
        }
        return nil
    }

    /// Number of leading characters that form a timestamp (0 if none).
    public static func timestampLength(in line: String) -> Int {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = leadingTimestamp.firstMatch(in: line, range: range), let r = Range(m.range, in: line) else { return 0 }
        return line.distance(from: line.startIndex, to: r.upperBound)
    }
}
