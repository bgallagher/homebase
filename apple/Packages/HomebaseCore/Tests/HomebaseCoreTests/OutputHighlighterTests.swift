import Foundation
import XCTest
@testable import HomebaseCore

private func spans(_ s: String) -> [(String, HighlightKind)] {
    let bytes = Array(s.utf8)
    return OutputHighlighter.spans(in: s).map { (String(decoding: bytes[$0.start..<$0.end], as: UTF8.self), $0.kind) }
}

final class OutputHighlighterTests: XCTestCase {
    func testIPv4() {
        let r = spans("IPv4 address for eth0: 89.167.95.123 and https://10.0.0.1:9090/ ok")
        XCTAssertEqual(r.map(\.0), ["89.167.95.123", "10.0.0.1"])
        XCTAssertTrue(r.allSatisfy { $0.1 == .ipAddress })
    }

    func testIPv4Rejections() {
        XCTAssertTrue(spans("version 1.2.3 and 256.1.1.1 and 1.2.3.4.5 and 300.300.300.300").isEmpty,
                      "out-of-range octets and 5-part dotted numbers are not IPs")
        XCTAssertTrue(spans("abc1.2.3.4").isEmpty, "must not start inside a word")
    }

    func testIPv6() {
        XCTAssertEqual(spans("IPv6 address for eth0: 2a01:4f9:c014:2ddc::1").map(\.0), ["2a01:4f9:c014:2ddc::1"])
        XCTAssertEqual(spans("link fe80::1 up").map(\.0), ["fe80::1"])
        XCTAssertEqual(spans("2001:0db8:0000:0000:0000:ff00:0042:8329").map(\.0), ["2001:0db8:0000:0000:0000:ff00:0042:8329"])
    }

    func testIPv6LookalikesAreIgnored() {
        XCTAssertTrue(spans("at 11:26:02 PM").isEmpty, "a time")
        XCTAssertTrue(spans("mac aa:bb:cc:dd:ee:ff end").isEmpty, "a MAC address")
        XCTAssertTrue(spans("ratio 3:1").isEmpty)
    }

    func testWords() {
        XCTAssertEqual(spans("Build FAILED: permission denied").map(\.1), [.error, .error])
        XCTAssertEqual(spans("warning: deprecated").map(\.1), [.warning])
        XCTAssertEqual(spans("Tests passed. Successfully installed").map(\.1), [.success, .success])
        XCTAssertTrue(spans("errors: 0, terror, warned").isEmpty, "whole words only; plurals and substrings are not matched")
    }

    func testPercentThresholds() {
        XCTAssertEqual(spans("Usage of /: 91% of 37G").map { "\($0.0)|\($0.1)" }, ["91%|error"])
        XCTAssertEqual(spans("disk 80%").map { "\($0.0)|\($0.1)" }, ["80%|warning"])
        XCTAssertTrue(spans("cpu 43.1% of 37.23GB").isEmpty)
        XCTAssertEqual(spans("use 99.5%").map(\.0), ["99.5%"])
    }

    func testOffsetsAreUTF8BytesEvenWithMultibyteText() {
        let s = "héllo 日本 10.0.0.1"
        let sp = OutputHighlighter.spans(in: s)
        XCTAssertEqual(sp.count, 1)
        XCTAssertEqual(String(decoding: Array(s.utf8)[sp[0].start..<sp[0].end], as: UTF8.self), "10.0.0.1")
    }

    func testOverlapsKeepTheEarlierSpan() {
        let r = OutputHighlighter.resolve([
            HighlightSpan(start: 0, end: 5, kind: .error), HighlightSpan(start: 3, end: 8, kind: .warning),
            HighlightSpan(start: 8, end: 9, kind: .success)])
        XCTAssertEqual(r.map(\.kind), [.error, .success])
    }
}

final class TerminalOutputFilterTests: XCTestCase {
    private let ESC = "\u{1B}"
    private func run(_ filter: inout TerminalOutputFilter, _ s: String) -> String {
        String(decoding: filter.process(Array(s.utf8)), as: UTF8.self)
    }
    /// Removes exactly the colour pairs the filter inserts, to prove it never changes anything else.
    private func stripInjected(_ s: String) -> String {
        var t = s
        for c in ["31", "32", "33", "35"] { t = t.replacingOccurrences(of: "\u{1B}[\(c)m", with: "") }
        return t.replacingOccurrences(of: "\u{1B}[39m", with: "")
    }

    func testColoursAnIPInPlainOutput() {
        var f = TerminalOutputFilter()
        let out = run(&f, "IPv4 address for eth0: 89.167.95.123\r\nnext line\r\n")
        XCTAssertEqual(out, "IPv4 address for eth0: \(ESC)[35m89.167.95.123\(ESC)[39m\r\nnext line\r\n")
    }

    func testDisabledIsAnExactPassThrough() {
        var f = TerminalOutputFilter()
        f.isEnabled = false
        let s = "error at 10.0.0.1 \(ESC)[1;31mred\(ESC)[0m\r\n"
        XCTAssertEqual(f.process(Array(s.utf8)), Array(s.utf8))
    }

    func testLeavesProgramColouredTextAlone() {
        var f = TerminalOutputFilter()
        let s = "\(ESC)[32mserver 10.0.0.1\(ESC)[0m and 10.0.0.2\r\n"
        let out = run(&f, s)
        XCTAssertFalse(out.contains("\(ESC)[35m10.0.0.1"), "inside the program's own green")
        XCTAssertTrue(out.contains("\(ESC)[35m10.0.0.2\(ESC)[39m"), "after reset, highlighting resumes")
    }

    func testBackgroundAnd256ColourAndReverseAlsoSuppress() {
        for set in ["\(ESC)[44m", "\(ESC)[38;5;196m", "\(ESC)[38;2;1;2;3m", "\(ESC)[7m", "\(ESC)[1;33;40m"] {
            var f = TerminalOutputFilter()
            XCTAssertEqual(run(&f, "\(set)10.0.0.1 \r\n"), "\(set)10.0.0.1 \r\n", set)
        }
        var f = TerminalOutputFilter()
        _ = run(&f, "\(ESC)[7m")
        XCTAssertEqual(run(&f, "\(ESC)[27m10.0.0.1 x"), "\(ESC)[27m\(ESC)[35m10.0.0.1\(ESC)[39m x", "27 clears reverse")
    }

    func testSubparameterFormsDoNotBreakTracking() {
        var f = TerminalOutputFilter()
        // 38;5;n consumes its own parameters, so the trailing 0 is a real reset.
        let out = run(&f, "\(ESC)[38;5;196;0m10.0.0.1 x")
        XCTAssertTrue(out.contains("\(ESC)[35m10.0.0.1"), "reset after a 256-colour parameter is honoured")
    }

    func testAlternateScreenIsNeverTouched() {
        var f = TerminalOutputFilter()
        let out = run(&f, "\(ESC)[?1049h10.0.0.1 error \(ESC)[?1049l and 10.0.0.2 x")
        XCTAssertTrue(out.contains("\(ESC)[?1049h10.0.0.1 error \(ESC)[?1049l"))
        XCTAssertTrue(out.contains("\(ESC)[35m10.0.0.2\(ESC)[39m"))
    }

    func testEscapeSequencesPassThroughUnchanged() {
        var f = TerminalOutputFilter()
        // Window title containing an IP, a charset select, cursor movement, and a DCS string.
        let s = "\(ESC)]0;root@10.0.0.1: ~\u{07}\(ESC)(B\(ESC)[2;5H\(ESC)[K\(ESC)Pq10.0.0.2\(ESC)\\hello\r\n"
        XCTAssertEqual(run(&f, s), s)
    }

    func testChunkEdgeMatchesAreSkippedNotMangled() {
        var f = TerminalOutputFilter()
        let a = run(&f, "ip 10.0.0.1")        // ends exactly at the token: might continue
        let b = run(&f, "23 done\r\n")        // continues it
        XCTAssertEqual(a + b, "ip 10.0.0.123 done\r\n", "no colour is better than a wrong colour")
    }

    func testTypedEchoByteByByteIsUnchanged() {
        var f = TerminalOutputFilter()
        var all = ""
        for ch in "ping 10.0.0.1\r\n" { all += run(&f, String(ch)) }
        XCTAssertEqual(all, "ping 10.0.0.1\r\n")
    }

    func testMultibyteCharactersSplitAcrossChunks() {
        var f = TerminalOutputFilter()
        let bytes = Array("café 日本 10.0.0.1 x\r\n".utf8)
        var out: [UInt8] = []
        for b in bytes { out += f.process([b]) }
        out += f.process([])
        XCTAssertEqual(stripInjected(String(decoding: out, as: UTF8.self)), "café 日本 10.0.0.1 x\r\n")
    }

    /// Whatever the chunking, the filter must only ever add colour pairs.
    func testRandomChunkingNeverCorruptsOutput() {
        let corpus = "System load: 0.44  Usage of /: 91% of 37G\r\nIPv4 address for eth0: 89.167.95.123\r\n"
            + "\(ESC)[1;32mok\(ESC)[0m build FAILED at 10.0.0.9\r\nIPv6: 2a01:4f9:c014:2ddc::1 warning: x\r\n"
            + "\(ESC)]0;title 10.0.0.1\u{07}\(ESC)[?1049hfull screen 1.2.3.4\(ESC)[?1049l tail 8.8.8.8 \r\n"
        let bytes = Array(corpus.utf8)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var f = TerminalOutputFilter()
            var out: [UInt8] = []
            var i = 0
            while i < bytes.count {
                let n = Int.random(in: 1...9, using: &rng)
                out += f.process(Array(bytes[i..<min(i + n, bytes.count)]))
                i += n
            }
            out += f.process([])
            XCTAssertEqual(stripInjected(String(decoding: out, as: UTF8.self)), corpus)
        }
    }

    func testStateIsTrackedWhileDisabledSoEnablingMidStreamIsCorrect() {
        var f = TerminalOutputFilter()
        f.isEnabled = false
        let off = run(&f, "\(ESC)[?1049h")                       // vim starts while highlighting is off
        XCTAssertEqual(off, "\(ESC)[?1049h", "disabled output is untouched")
        f.isEnabled = true
        XCTAssertEqual(run(&f, "inside vim 10.0.0.1 x"), "inside vim 10.0.0.1 x", "still on the alternate screen: no colour")
        XCTAssertTrue(run(&f, "\(ESC)[?1049l back 10.0.0.2 x").contains("\(ESC)[35m10.0.0.2"), "colour returns after vim exits")

        var g = TerminalOutputFilter()
        g.isEnabled = false
        _ = run(&g, "\(ESC)[32m")                                // a program sets green while we are off
        g.isEnabled = true
        XCTAssertEqual(run(&g, "10.0.0.1 x"), "10.0.0.1 x", "the program's own colour is still respected")
    }

    /// The strongest "off" guarantee: for ANY bytes, a disabled filter returns exactly what it was given.
    func testDisabledFilterIsAnExactIdentityForArbitraryBytes() {
        var rng = SystemRandomNumberGenerator()
        var f = TerminalOutputFilter()
        f.isEnabled = false
        var specials: [UInt8] = Array("\u{1B}[0m\u{1B}]0;t\u{07}\u{1B}[?1049h 10.0.0.1 error 99%\r\n".utf8)
        for _ in 0..<3000 {
            let n = Int.random(in: 0...80, using: &rng)
            let chunk = (0..<n).map { _ in Bool.random(using: &rng) ? specials.randomElement(using: &rng)! : UInt8.random(in: 0...255, using: &rng) }
            XCTAssertEqual(f.process(chunk), chunk)
        }
        specials.removeAll()
    }

    func testFastPathDoesNotLoseStateAcrossAnEscapeLater() {
        var f = TerminalOutputFilter()
        f.isEnabled = false
        XCTAssertEqual(run(&f, "plain text with no escapes at all\r\n"), "plain text with no escapes at all\r\n")
        _ = run(&f, "\(ESC)[?1049h")                     // slow path: tracks the alternate screen
        XCTAssertEqual(run(&f, "10.0.0.1 more plain bytes"), "10.0.0.1 more plain bytes")   // fast path again
        f.isEnabled = true
        XCTAssertEqual(run(&f, "10.0.0.1 x"), "10.0.0.1 x", "the alternate screen was remembered through the fast path")
    }

    func testDisabledFilterHoldsNothingBack() {
        var f = TerminalOutputFilter()
        f.isEnabled = false
        let euro: [UInt8] = [0xE2, 0x82, 0xAC]
        XCTAssertEqual(f.process(Array(euro.prefix(2))), Array(euro.prefix(2)), "no buffering when off")
        XCTAssertEqual(f.finish(), [])
    }

    func testFinishReleasesAHeldBackPartialCharacter() {
        var f = TerminalOutputFilter()
        let euro: [UInt8] = [0xE2, 0x82, 0xAC]
        XCTAssertEqual(f.process(Array(euro.prefix(2))), [], "incomplete character is held back")
        XCTAssertEqual(f.finish(), Array(euro.prefix(2)), "and released unmodified when the stream ends")
        XCTAssertEqual(f.finish(), [])
    }

    func testGarbageInputNeverCrashes() {
        var rng = SystemRandomNumberGenerator()
        var f = TerminalOutputFilter()
        for _ in 0..<2000 {
            let n = Int.random(in: 0...64, using: &rng)
            _ = f.process((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
    }
}
