import Foundation

/// Runs a command with live output over a pty and reports its exit code in-band, as a final marker line.
/// (A streamed ssh gives output but no exit status, so the wrapper prints `##rackoon-exit:<n>` itself.)
public enum StreamedCommand {
    public static let template = ###"stty cols {cols} rows {rows} 2>/dev/null; ( {command} ); rk=$?; echo; echo "##rackoon-exit:$rk""###
    public static let marker = "##rackoon-exit:"

    /// `cols` and `rows` are the size of the terminal that will show the output, so progress that redraws itself
    /// (compose moves the cursor up to update lines) lines up. The command itself must already be vetted.
    public static func wrap(_ command: String, cols: Int, rows: Int) -> String {
        Template.fill(template, ["cols": String(min(max(cols, 20), 400)), "rows": String(min(max(rows, 5), 200)), "command": command])
    }
}

/// Splits a stream into the text to show and the exit code marker at its end. Chunks can cut the marker anywhere,
/// so a possible start of it is held back until the next chunk shows what it is.
public struct StreamOutputParser: Sendable {
    private var pending = ""
    public private(set) var exitCode: Int32?

    public init() {}

    /// Text that is safe to show now.
    public mutating func push(_ chunk: String) -> String {
        guard exitCode == nil else { return "" }          // nothing follows the marker
        pending += chunk
        if let found = pending.range(of: StreamedCommand.marker) {
            let shown = String(pending[..<found.lowerBound])
            let rest = pending[found.upperBound...]
            // Work on unicode scalars: Swift treats "\r\n" as ONE Character that equals neither "\r" nor "\n", so a
            // Character search never finds the end of the line in real pty output.
            if let end = rest.unicodeScalars.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                exitCode = Self.leadingInt(String(rest.unicodeScalars[..<end]))
                pending = ""
            } else {
                pending = String(pending[found.lowerBound...])   // the number has not fully arrived
            }
            return shown
        }
        // Hold back a tail that could be the start of the marker.
        var hold = 0
        for length in stride(from: min(StreamedCommand.marker.count - 1, pending.count), through: 1, by: -1) {
            if StreamedCommand.marker.hasPrefix(String(pending.suffix(length))) { hold = length; break }
        }
        let cut = pending.index(pending.endIndex, offsetBy: -hold)
        let shown = String(pending[..<cut])
        pending = String(pending[cut...])
        return shown
    }

    /// At the end of the stream: whatever was held back, and the exit code if the marker arrived (nil if the
    /// connection ended or the command was cancelled before it finished).
    public mutating func finish() -> (text: String, exitCode: Int32?) {
        defer { pending = "" }
        if exitCode == nil, let found = pending.range(of: StreamedCommand.marker) {
            // The marker was the last thing sent, without a trailing newline.
            if let code = Self.leadingInt(String(pending[found.upperBound...])) {
                exitCode = code
                return (String(pending[..<found.lowerBound]), code)
            }
        }
        return (exitCode == nil ? pending : "", exitCode)
    }

    /// The number at the start of `text`, ignoring spaces before it and anything after it.
    private static func leadingInt(_ text: String) -> Int32? {
        let digits = text.unicodeScalars.drop(while: { $0 == " " }).prefix(while: { $0.value >= 48 && $0.value <= 57 })
        return Int32(String(String.UnicodeScalarView(digits)))
    }
}

/// Reassembles UTF-8 from byte chunks that may cut a multi-byte character in two (compose prints ✔).
public struct Utf8Chunker: Sendable {
    private var held = Data()
    public init() {}

    public mutating func push(_ data: Data) -> String {
        held.append(data)
        // A character is at most 4 bytes (a lead byte and up to 3 continuations): hold back an incomplete tail.
        var end = held.count
        var back = 0
        while back < 4, end - back > 0 {
            let byte = held[held.startIndex + end - back - 1]
            if byte & 0b1100_0000 == 0b1000_0000 { back += 1; continue }          // continuation byte: keep looking
            let needed = byte >= 0b1111_0000 ? 4 : byte >= 0b1110_0000 ? 3 : byte >= 0b1100_0000 ? 2 : 1
            if needed > back + 1 { end -= back + 1 }                                  // lead byte without its continuations
            break
        }
        let text = String(decoding: held.prefix(end), as: UTF8.self)
        held = Data(held.suffix(held.count - end))
        return text
    }

    public mutating func finish() -> String {
        defer { held = Data() }
        return held.isEmpty ? "" : String(decoding: held, as: UTF8.self)
    }
}

public enum ActionStreamEvent: Sendable, Equatable {
    case output(String)
    /// `exitCode` is nil if the connection ended or the run was cancelled before the command reported one.
    case finished(exitCode: Int32?)
}
