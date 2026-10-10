import Foundation

/// Rewrites a terminal's output byte stream to add colour (see OutputHighlighter) without ever changing
/// what the terminal would otherwise show: it only inserts SGR "set foreground" / "default foreground"
/// pairs around matched text.
///
/// Safety rules, all covered by tests:
/// - Escape sequences are copied through untouched, including OSC titles, charset selects and SGR.
/// - Nothing is coloured while a program has set its own colours (foreground, background or reverse video),
///   so `ls --color`, shell prompts and syntax highlighters are left alone.
/// - Nothing is coloured on the alternate screen (vim, htop, less), tracked from DECSET 47/1047/1049.
/// - A match touching the end of a chunk, or continuing from the previous chunk's last token, is skipped:
///   it may be part of a longer token. Typed echo therefore stays plain, and a token split across two reads
///   is simply not coloured rather than coloured wrongly.
/// - An incomplete UTF-8 sequence at the end of a chunk is carried to the next call (only while enabled).
public struct TerminalOutputFilter {
    /// Controls only whether colour is *inserted*. Escape-sequence state (program colours, alternate screen)
    /// is tracked either way, so switching on in the middle of a stream is immediately correct (for example
    /// while vim is open) and switching off gives a byte-for-byte pass-through.
    public var isEnabled = true

    private enum Mode { case text, esc, escIntermediate, csi, osc, oscEsc }
    private var mode = Mode.text
    private var csi: [UInt8] = []
    private var fgActive = false, bgActive = false, reverse = false, altScreen = false
    private var carry: [UInt8] = []
    private var endsWithTokenByte = false

    public init() {}

    static func sgr(_ kind: HighlightKind) -> [UInt8] {
        let code: String
        switch kind {
        case .ipAddress: code = "35"
        case .error: code = "31"
        case .warning: code = "33"
        case .success: code = "32"
        }
        return Array("\u{1B}[\(code)m".utf8)
    }
    private static let resetForeground = Array("\u{1B}[39m".utf8)

    public mutating func process(_ input: [UInt8]) -> [UInt8] {
        // Fast path for the common "off" case: with highlighting disabled and no escape byte in this chunk
        // (and none half-parsed from the last one), nothing can change our state or the output, so hand the
        // bytes straight back instead of running the per-byte state machine over, say, `cat bigfile`.
        if !isEnabled, mode == .text, carry.isEmpty, !input.contains(0x1B) {
            if let last = input.last, !(last < 0x20 || last == 0x7F) { endsWithTokenByte = Self.isTokenByte(last) }
            else if !input.isEmpty { endsWithTokenByte = false }
            return input
        }
        let data = carry + input
        carry = []
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 32)
        var run: [UInt8] = []

        for b in data {
            switch mode {
            case .text:
                if b == 0x1B {
                    flush(&run, into: &out, atChunkEnd: false)
                    out.append(b)
                    mode = .esc
                } else if b < 0x20 || b == 0x7F {
                    flush(&run, into: &out, atChunkEnd: false)
                    out.append(b)
                    endsWithTokenByte = false
                } else {
                    run.append(b)
                }
            case .esc:
                out.append(b)
                switch b {
                case 0x5B: mode = .csi; csi = []
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: mode = .osc   // OSC, DCS, SOS, PM, APC: run to a string terminator
                case 0x20...0x2F: mode = .escIntermediate        // e.g. ESC ( B
                case 0x63: resetStyleState(); mode = .text       // RIS
                default: mode = .text
                }
            case .escIntermediate:
                out.append(b)
                if !(0x20...0x2F).contains(b) { mode = .text }
            case .csi:
                out.append(b)
                if (0x40...0x7E).contains(b) {
                    finishCSI(final: b)
                    mode = .text
                } else {
                    csi.append(b)
                }
            case .osc:
                out.append(b)
                if b == 0x07 { mode = .text } else if b == 0x1B { mode = .oscEsc }
            case .oscEsc:
                out.append(b)
                mode = b == 0x5C ? .text : .osc   // ESC \ ends it; any other byte is still inside the string
            }
        }

        // Keep an incomplete trailing UTF-8 sequence for the next call instead of splitting a character.
        // Only hold bytes back when we might rewrite them; a disabled filter passes everything straight through.
        let tail = isEnabled ? Self.incompleteUTF8Tail(run) : 0
        if tail > 0 {
            carry = Array(run.suffix(tail))
            run.removeLast(tail)
        }
        flush(&run, into: &out, atChunkEnd: true)
        return out
    }

    /// Call once when the stream ends: returns any bytes still held back (an incomplete UTF-8 tail), unmodified.
    public mutating func finish() -> [UInt8] {
        defer { carry = [] }
        return carry
    }

    // MARK: - Text runs

    private mutating func flush(_ run: inout [UInt8], into out: inout [UInt8], atChunkEnd: Bool) {
        defer { run.removeAll(keepingCapacity: true) }
        guard !run.isEmpty else { return }
        let wasAdjacent = endsWithTokenByte
        endsWithTokenByte = Self.isTokenByte(run[run.count - 1])

        guard isEnabled, !altScreen, !fgActive, !bgActive, !reverse,
              let text = String(bytes: run, encoding: .utf8) else {
            out.append(contentsOf: run)
            return
        }
        var cursor = 0
        for span in OutputHighlighter.spans(in: text) {
            if atChunkEnd && span.end == run.count { continue }      // may continue in the next chunk
            if wasAdjacent && span.start == 0 { continue }           // may continue the previous chunk's token
            out.append(contentsOf: run[cursor..<span.start])
            out.append(contentsOf: Self.sgr(span.kind))
            out.append(contentsOf: run[span.start..<span.end])
            out.append(contentsOf: Self.resetForeground)
            cursor = span.end
        }
        out.append(contentsOf: run[cursor...])
    }

    private static func isTokenByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == 0x2E || b == 0x3A || b == 0x25 || b == 0x5F || b >= 0x80
    }

    private static func incompleteUTF8Tail(_ bytes: [UInt8]) -> Int {
        var i = bytes.count - 1
        var back = 0
        while i >= 0, back < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }          // continuation byte
            let needed = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : (b >= 0xC0 ? 2 : 1))
            return needed > back + 1 ? back + 1 : 0
        }
        return 0
    }

    // MARK: - Escape sequence state

    private mutating func resetStyleState() {
        fgActive = false; bgActive = false; reverse = false; altScreen = false
    }

    private mutating func finishCSI(final: UInt8) {
        let text = String(decoding: csi, as: UTF8.self)
        switch final {
        case UInt8(ascii: "m") where !text.hasPrefix("?") && !text.hasPrefix(">") && !text.hasPrefix("<") && !text.hasPrefix("="):
            applySGR(text)
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            guard text.hasPrefix("?") else { return }
            for mode in text.dropFirst().split(separator: ";") where ["47", "1047", "1049"].contains(String(mode)) {
                altScreen = final == UInt8(ascii: "h")
            }
        default:
            break
        }
    }

    private mutating func applySGR(_ params: String) {
        let parts = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < parts.count {
            // "38:2::r:g:b" style sub-parameters: only the leading code matters here.
            let code = Int(parts[i].split(separator: ":", omittingEmptySubsequences: false).first ?? "") ?? 0
            switch code {
            case 0: fgActive = false; bgActive = false; reverse = false
            case 7: reverse = true
            case 27: reverse = false
            case 30...37, 90...97: fgActive = true
            case 39: fgActive = false
            case 40...47, 100...107: bgActive = true
            case 49: bgActive = false
            case 38, 48:
                if code == 38 { fgActive = true } else { bgActive = true }
                if !parts[i].contains(":") {
                    let kind = i + 1 < parts.count ? Int(parts[i + 1]) : nil
                    i += kind == 5 ? 2 : (kind == 2 ? 4 : 0)   // skip the colour's own parameters
                }
            default: break
            }
            i += 1
        }
    }
}
