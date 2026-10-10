import Foundation
import XCTest
@testable import RackoonCore

final class StreamParserTests: XCTestCase {
    private func run(_ chunks: [String]) -> (shown: String, exit: Int32?) {
        var p = StreamOutputParser()
        var shown = ""
        for c in chunks { shown += p.push(c) }
        let rest = p.finish()
        return (shown + rest.text, rest.exitCode)
    }

    func testOutputThenMarker() {
        let r = run(["[+] Restarting 1/1\r\n", " ✔ Container web  Started\r\n", "\r\n##rackoon-exit:0\r\n"])
        XCTAssertEqual(r.shown, "[+] Restarting 1/1\r\n ✔ Container web  Started\r\n\r\n")
        XCTAssertEqual(r.exit, 0)
    }

    func testMarkerSplitAtEveryPossiblePoint() {
        let text = "hello\r\n\r\n##rackoon-exit:17\r\n"
        for cut in 1..<text.count {
            let i = text.index(text.startIndex, offsetBy: cut)
            let r = run([String(text[..<i]), String(text[i...])])
            XCTAssertEqual(r.shown, "hello\r\n\r\n", "cut at \(cut)")
            XCTAssertEqual(r.exit, 17, "cut at \(cut)")
        }
    }

    /// The exact bytes a real `ssh -tt` run produced (captured from a server): the marker, a CRLF, then ssh's own
    /// message. A Character-based search for the end of the line missed the CRLF (one Character) and showed the marker.
    func testRealPtyTailWithSshsOwnMessageAfterTheMarker() {
        let real = "hello\r\n\r\n##rackoon-exit:0\r\nConnection to hetzner closed.\r\n"
        let r = run([real])
        XCTAssertEqual(r.shown, "hello\r\n\r\n")
        XCTAssertEqual(r.exit, 0)
        for cut in 1..<real.count {
            let i = real.index(real.startIndex, offsetBy: cut)
            let split = run([String(real[..<i]), String(real[i...])])
            XCTAssertEqual(split.shown, "hello\r\n\r\n", "cut at \(cut)")
            XCTAssertEqual(split.exit, 0, "cut at \(cut)")
        }
    }

    func testMultiDigitExitCodesAndNoNewlineAfterwards() {
        XCTAssertEqual(run(["x\r\n##rackoon-exit:130\r\nbye\r\n"]).exit, 130)
        XCTAssertEqual(run(["x\n##rackoon-exit:2"]).exit, 2)
    }

    func testByteAtATime() {
        let r = run("one\ntwo\n##rackoon-exit:3\n".map(String.init))
        XCTAssertEqual(r.shown, "one\ntwo\n")
        XCTAssertEqual(r.exit, 3)
    }

    func testMarkerWithoutATrailingNewlineStillCounts() {
        let r = run(["done\n##rackoon-exit:0"])
        XCTAssertEqual(r.shown, "done\n")
        XCTAssertEqual(r.exit, 0)
    }

    func testAHashInOrdinaryOutputIsNotHeldForever() {
        let r = run(["## heading\n", "#", "# not a marker\n"])
        XCTAssertEqual(r.shown, "## heading\n## not a marker\n")
        XCTAssertNil(r.exit)
    }

    func testStreamThatEndsWithoutAMarkerHasNoExitCode() {
        let r = run(["partial output", " more"])
        XCTAssertEqual(r.shown, "partial output more")
        XCTAssertNil(r.exit, "cancelled or dropped: unknown, never read as success")
    }

    func testNothingAfterTheMarkerIsShown() {
        let r = run(["a\n##rackoon-exit:1\n", "late noise\n"])
        XCTAssertEqual(r.shown, "a\n")
        XCTAssertEqual(r.exit, 1)
    }

    func testWrapperCommandShape() throws {
        let c = StreamedCommand.wrap("cd '/srv/a' && docker compose -p a -f '/srv/a/c.yaml' restart", cols: 100, rows: 24)
        XCTAssertEqual(c, ###"stty cols 100 rows 24 2>/dev/null; ( cd '/srv/a' && docker compose -p a -f '/srv/a/c.yaml' restart ); rk=$?; echo; echo "##rackoon-exit:$rk""###)
        XCTAssertTrue(StreamedCommand.wrap("x", cols: 1, rows: 1).hasPrefix("stty cols 20 rows 5"), "sizes are clamped")
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(StreamedCommand.template, commands.first { $0["id"] as? String == "stream_wrap" }?["script"] as? String)
    }
}

final class Utf8ChunkerTests: XCTestCase {
    func testASplitCharacterIsJoinedAcrossChunks() {
        let bytes = Array("a ✔ b 😀 c".utf8)
        for cut in 1..<bytes.count {
            var c = Utf8Chunker()
            let text = c.push(Data(bytes[..<cut])) + c.push(Data(bytes[cut...])) + c.finish()
            XCTAssertEqual(text, "a ✔ b 😀 c", "cut at \(cut)")
        }
    }

    func testByteAtATimeAndInvalidBytesDoNotHangOrLoseText() {
        var c = Utf8Chunker()
        var out = ""
        for b in Array("héllo ☕ wörld 😀".utf8) { out += c.push(Data([b])) }
        out += c.finish()
        XCTAssertEqual(out, "héllo ☕ wörld 😀")
        var junk = Utf8Chunker()
        let text = junk.push(Data([0xff, 0xfe, 0x80, 0x80, 0x80, 0x80, 0x41])) + junk.finish()
        XCTAssertTrue(text.hasSuffix("A"))
    }
}

final class StreamingActionTests: XCTestCase {
    private func stack() -> DockerStack {
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none",
                                status: "Up", ports: [], project: "media", service: "web", workingDir: "/srv/media",
                                configFile: "/srv/media/compose.yaml", configFiles: ["/srv/media/compose.yaml"])
        return DockerStack(name: "media", workingDir: "/srv/media", configFile: "/srv/media/compose.yaml",
                           configFiles: ["/srv/media/compose.yaml"], containers: [c], isStandalone: false)
    }
    private func snapshot() throws -> String {
        try String(contentsOf: specDir.appendingPathComponent("fixtures/docker/ubuntu-24.04-compose.out.txt"), encoding: .utf8)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ActionStreamEvent] = []
        func add(_ e: ActionStreamEvent) { lock.withLock { items.append(e) } }
        var events: [ActionStreamEvent] { lock.withLock { items } }
        var text: String { events.compactMap { if case .output(let s) = $0 { s } else { nil } }.joined() }
    }

    private func runStreaming(_ t: FakeTransport, policy: ActionPolicy = ActionPolicy(), confirm: Bool = true,
                              action: ComposeAction = .restart) async throws -> (Collector, DockerSession) {
        let session = DockerSession(transport: t, policy: policy)
        let got = Collector()
        let confirmation = confirm ? try? session.confirm(action, stack: stack()) : nil
        await session.performStreaming(action, stack: stack(), confirmation: confirmation, cols: 100, rows: 24, onEvent: { got.add($0) })
        return (got, session)
    }

    func testStreamsOutputReportsSuccessAndRefreshes() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: try snapshot()))])
        t.streamChunks = ["[+] Restarting 1/1\r\n", " ✔ Container web ", "Started\r\n\r\n##rack", "oon-exit:0\r\n"]
        let (got, session) = try await runStreaming(t)
        XCTAssertEqual(t.streamedCommands, [StreamedCommand.wrap(ComposeAction.restart.command(for: stack())!, cols: 100, rows: 24)])
        XCTAssertEqual(got.text, "[+] Restarting 1/1\r\n ✔ Container web Started\r\n\r\n")
        XCTAssertEqual(got.events.last, .finished(exitCode: 0))
        let state = await session.state
        XCTAssertNil(state.actionError)
        XCTAssertTrue(state.busy.isEmpty && state.busyStacks.isEmpty, "busy is cleared when it ends")
        XCTAssertEqual(t.commands.count, 1, "the list is refreshed afterwards")
        XCTAssertNotNil(state.snapshot)
    }

    func testAFailingCommandIsReportedWithItsExitCode() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: try snapshot()))])
        t.streamChunks = ["no configuration file provided\r\n", "\r\n##rackoon-exit:1\r\n"]
        let (got, session) = try await runStreaming(t, action: .pull)
        XCTAssertEqual(got.events.last, .finished(exitCode: 1))
        let error = await session.state.actionError
        XCTAssertEqual(error, "docker compose pull failed (exit 1). The output shows why.")
    }

    func testAStreamThatEndsWithoutAnExitCodeIsNeverASuccess() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: try snapshot()))])
        t.streamChunks = ["Pulling…\r\n"]
        let (got, session) = try await runStreaming(t, action: .up)
        XCTAssertEqual(got.events.last, .finished(exitCode: nil))
        let error = await session.state.actionError
        XCTAssertEqual(error, "The connection ended before docker compose up reported a result.")
    }

    func testNothingStartsWithoutConfirmationOrInReadOnlyMode() async throws {
        let t = FakeTransport([])
        t.streamChunks = ["should never run"]
        var (got, session) = try await runStreaming(t, confirm: false)
        XCTAssertTrue(t.streamedCommands.isEmpty)
        XCTAssertEqual(got.events, [.finished(exitCode: nil)])
        var error = await session.state.actionError
        XCTAssertEqual(error, PolicyError.notConfirmed.errorDescription)

        (got, session) = try await runStreaming(t, policy: ActionPolicy(readOnly: true))
        XCTAssertTrue(t.streamedCommands.isEmpty)
        error = await session.state.actionError
        XCTAssertEqual(error, PolicyError.readOnly.errorDescription)
    }

    func testContainerActionsStreamToo() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: try snapshot()))])
        t.streamChunks = ["abcdef012345\r\n", "\r\n##rackoon-exit:0\r\n"]
        let session = DockerSession(transport: t)
        let got = Collector()
        let confirmation = try session.confirm(.restart, containerID: "abcdef012345")
        await session.performStreaming(.restart, containerID: "abcdef012345", confirmation: confirmation, cols: 90, rows: 20, onEvent: { got.add($0) })
        XCTAssertEqual(t.streamedCommands, [StreamedCommand.wrap("docker restart abcdef012345", cols: 90, rows: 20)])
        XCTAssertEqual(got.text, "abcdef012345\r\n\r\n")
        XCTAssertEqual(got.events.last, .finished(exitCode: 0))
        let state = await session.state
        XCTAssertTrue(state.busy.isEmpty)
        XCTAssertNil(state.actionError)
        XCTAssertEqual(t.commands.count, 1, "refreshed afterwards")
    }

    func testContainerStreamingRefusesBadIdsAndMissingConfirmation() async throws {
        let t = FakeTransport([])
        t.streamChunks = ["should never run"]
        let session = DockerSession(transport: t)
        let got = Collector()
        await session.performStreaming(.stop, containerID: "x; reboot", confirmation: nil, cols: 80, rows: 24, onEvent: { got.add($0) })
        await session.performStreaming(.stop, containerID: "abcdef012345", confirmation: nil, cols: 80, rows: 24, onEvent: { got.add($0) })
        XCTAssertTrue(t.streamedCommands.isEmpty)
        XCTAssertEqual(got.events, [.finished(exitCode: nil), .finished(exitCode: nil)])
        let error = await session.state.actionError
        XCTAssertEqual(error, PolicyError.notConfirmed.errorDescription)
    }

    func testSentinelLookalikesInOutputDoNotEndTheRunEarly() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: try snapshot()))])
        t.streamChunks = ["service says: ##rackoon-exit is a marker name\r\n", "real output\r\n\r\n##rackoon-exit:0\r\n"]
        let (got, _) = try await runStreaming(t)
        XCTAssertEqual(got.events.last, .finished(exitCode: 0))
    }
}
