import Foundation

/// Turns streamed log chunks into lines. Chunks arrive split anywhere, and the remote pseudo-terminal
/// ends lines with \r\n, so this joins partial lines, normalises endings and caps memory.
public struct LogBuffer: Sendable, Equatable {
    public private(set) var lines: [String] = []
    private var partial = ""
    public let maxLines: Int

    public init(maxLines: Int = 2000) { self.maxLines = maxLines }

    public mutating func append(_ chunk: String) {
        let text = partial + chunk.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var pieces = text.components(separatedBy: "\n")
        partial = pieces.removeLast()
        // ssh prints this itself when the remote command ends; it is not part of the logs.
        lines.append(contentsOf: pieces.filter { !($0.hasPrefix("Connection to ") && $0.hasSuffix(" closed.")) })
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    /// Everything received so far, including a final line that has no newline yet.
    public var text: String { (lines + (partial.isEmpty ? [] : [partial])).joined(separator: "\n") }
}
