import Foundation
import XCTest
@testable import RackoonCore

final class DockerParserTests: XCTestCase {
    /// Every fixture in spec/fixtures/docker must parse to its expected JSON (shared with the Kotlin core).
    /// Error fixtures expect {"error": "...", "message"?: "..."}.
    /// Run with RACKOON_WRITE_GOLDEN=1 to write any missing expected file, then review it before committing.
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/docker")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") }.sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(outs.count, 4)
        for out in outs {
            let expectedURL = URL(fileURLWithPath: out.path.replacingOccurrences(of: ".out.txt", with: ".expected.json"))
            let actual = parsedJSON(try String(contentsOf: out, encoding: .utf8))
            if !FileManager.default.fileExists(atPath: expectedURL.path),
               ProcessInfo.processInfo.environment["RACKOON_WRITE_GOLDEN"] != nil {
                let data = try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: expectedURL)
                XCTFail("wrote \(expectedURL.lastPathComponent): review it, then commit")
                continue
            }
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? NSDictionary
            XCTAssertEqual(actual, expected, out.lastPathComponent)
        }
    }

    private func parsedJSON(_ text: String) -> NSDictionary {
        do {
            let snapshot = try DockerParser.parse(text)
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! NSDictionary
        } catch DockerParseError.notInstalled {
            return ["error": "notInstalled"]
        } catch DockerParseError.daemon(let m) {
            return ["error": "daemon", "message": m]
        } catch {
            return ["error": "other", "message": "\(error)"]
        }
    }

    func testCommandsMatchSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func script(_ id: String) -> String? { commands.first { $0["id"] as? String == id }?["script"] as? String }
        XCTAssertEqual(DockerSession.command, script("docker"))
        for action in DockerAction.allCases {
            XCTAssertEqual(script("docker_\(action.rawValue)"), "docker \(action.rawValue) {id}")
            XCTAssertEqual(DockerSession.actionCommand(action, id: "abcdef012345"), "docker \(action.rawValue) abcdef012345")
        }
    }

    func testActionRejectsAnythingButAHexID() {
        for bad in ["", "abc", "abcdef012345; rm -rf /", "ABCDEF012345", "abcdef01234g", "$(whoami)abcdef", "a b c d e f 0 1 2 3 4 5", String(repeating: "a", count: 65)] {
            XCTAssertNil(DockerSession.actionCommand(.restart, id: bad), bad)
        }
        XCTAssertNotNil(DockerSession.actionCommand(.stop, id: String(repeating: "a", count: 64)))
    }

    func testStacksGroupByProjectWithStandaloneLast() throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/docker/synthetic-mixed-states.out.txt"), encoding: .utf8)
        let stacks = try DockerParser.parse(text).stacks
        XCTAssertEqual(stacks.map(\.name), ["dockge", "monitoring", "shlink", "watchtower", "Standalone"])
        let monitoring = try XCTUnwrap(stacks.first { $0.name == "monitoring" })
        XCTAssertEqual(monitoring.configFileName, "compose.yaml")
        XCTAssertEqual(monitoring.stoppedCount, 1, "grafana is exited in this fixture")
        XCTAssertEqual(monitoring.unhealthyCount, 1, "prometheus is unhealthy in this fixture")
        XCTAssertTrue(try XCTUnwrap(stacks.last).isStandalone)
    }

    func testStackHealthAndSearch() throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/docker/synthetic-mixed-states.out.txt"), encoding: .utf8)
        let stacks = try DockerParser.parse(text).stacks
        let monitoring = try XCTUnwrap(stacks.first { $0.name == "monitoring" })
        XCTAssertEqual(monitoring.health, .attention, "one exited and one unhealthy container")
        XCTAssertTrue(monitoring.matches("MONITOR"))
        XCTAssertTrue(monitoring.matches("grafana"), "a container's name or service matches")
        XCTAssertTrue(monitoring.matches(""))
        XCTAssertFalse(monitoring.matches("monitoring shlink"), "every word must match")
        var empty = monitoring
        empty.containers = []
        XCTAssertEqual(empty.health, .stopped, "never started")
        var allUp = monitoring
        allUp.containers = monitoring.containers.map { var c = $0; c.state = "running"; c.health = ""; return c }
        XCTAssertEqual(allUp.health, .running)
        var allDown = monitoring
        allDown.containers = monitoring.containers.map { var c = $0; c.state = "exited"; c.health = ""; return c }
        XCTAssertEqual(allDown.health, .stopped)
    }

    func testPorts() {
        let ports = DockerParser.parsePorts("127.0.0.1:8087->8080/tcp, [::]:8087->8080/tcp, 172.17.0.1:8087->8080/tcp, 5432/tcp, 67-68/udp, 0.0.0.0:53->53/udp, 0.0.0.0:8000-8010->8000-8010/tcp")
        XCTAssertEqual(ports, [.init(hostPort: 8087, containerPort: 8080, proto: "tcp"),
                               .init(hostPort: 53, containerPort: 53, proto: "udp")],
                       "published only, one per host port, ranges skipped")
    }

    func testSizesAndPercent() {
        XCTAssertEqual(DockerParser.parseSize("255.8MiB"), 268_225_741)
        XCTAssertEqual(DockerParser.parseSize("7.57GiB"), 8_128_225_608)
        XCTAssertEqual(DockerParser.parseSize("115kB"), 115_000)
        XCTAssertEqual(DockerParser.parseSize("0B"), 0)
        XCTAssertNil(DockerParser.parseSize("lots"))
        XCTAssertEqual(DockerParser.parsePercent("0.03%"), 0.03)
        XCTAssertNil(DockerParser.parsePercent("--"))
    }

    func testHealthFallsBackToStatusTextForOlderDocker() {
        XCTAssertEqual(DockerParser.health(nil, status: "Up 2 hours (healthy)"), "healthy")
        XCTAssertEqual(DockerParser.health("", status: "Up 1 minute (unhealthy)"), "unhealthy")
        XCTAssertEqual(DockerParser.health(nil, status: "Up 3 seconds (health: starting)"), "starting")
        XCTAssertEqual(DockerParser.health(nil, status: "Up 2 hours"), "none")
        XCTAssertEqual(DockerParser.health("unhealthy", status: "Up"), "unhealthy")
    }

    func testLabelValuesMayContainCommas() {
        let m = DockerParser.parseLabels("a=1,com.docker.compose.project.config_files=/x/a.yaml,/x/b.yaml,b=2")
        XCTAssertEqual(m["com.docker.compose.project.config_files"], "/x/a.yaml,/x/b.yaml")
        XCTAssertEqual(m["b"], "2")
    }
}

final class DockerSessionTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: specDir.appendingPathComponent("fixtures/docker/\(name).out.txt"), encoding: .utf8)
    }

    func testRefreshPublishesSnapshot() async throws {
        let session = DockerSession(transport: FakeTransport([.success(CommandResult(stdout: try fixture("ubuntu-24.04-compose")))]))
        await session.refresh()
        let state = await session.state
        XCTAssertEqual(state.snapshot?.containers.count, 8)
        XCTAssertNil(state.error)
    }

    func testNotInstalledAndDaemonErrorsKeepLastSnapshot() async throws {
        let session = DockerSession(transport: FakeTransport([
            .success(CommandResult(stdout: try fixture("ubuntu-24.04-compose"))),
            .success(CommandResult(stdout: try fixture("synthetic-permission-denied"))),
            .success(CommandResult(stdout: try fixture("synthetic-docker-missing"))),
        ]))
        await session.refresh()
        await session.refresh()
        var state = await session.state
        XCTAssertNotNil(state.snapshot, "last good data stays")
        XCTAssertTrue(state.error?.contains("permission denied") == true)
        await session.refresh()
        state = await session.state
        XCTAssertEqual(state.error, "Docker is not installed on this server.")
    }

    func testRestartRunsCommandThenRefreshes() async throws {
        let transport = FakeTransport([
            .success(CommandResult(stdout: "abcdef012345\n")),                      // docker restart
            .success(CommandResult(stdout: try fixture("ubuntu-24.04-compose"))),   // refresh after
        ])
        let session = DockerSession(transport: transport)
        await session.perform(.restart, containerID: "abcdef012345", confirmation: try? session.confirm(.restart, containerID: "abcdef012345"))
        XCTAssertEqual(transport.commands.first, "docker restart abcdef012345")
        XCTAssertEqual(transport.commands.count, 2)
        let state = await session.state
        XCTAssertTrue(state.busy.isEmpty)
        XCTAssertNil(state.actionError)
        XCTAssertNotNil(state.snapshot)
    }

    func testFailedActionIsReportedAndInvalidIDNeverRuns() async throws {
        let transport = FakeTransport([
            .success(CommandResult(stdout: "", stderr: "Error: No such container", exitCode: 1)),
            .success(CommandResult(stdout: try fixture("ubuntu-24.04-compose"))),
        ])
        let session = DockerSession(transport: transport)
        await session.perform(.stop, containerID: "abcdef012345", confirmation: try? session.confirm(.stop, containerID: "abcdef012345"))
        var state = await session.state
        XCTAssertEqual(state.actionError, "Error: No such container")

        await session.perform(.stop, containerID: "x; reboot", confirmation: try? session.confirm(.stop, containerID: "x; reboot"))
        state = await session.state
        XCTAssertEqual(transport.commands.count, 2, "invalid id was not sent")
        XCTAssertTrue(state.actionError?.contains("invalid container id") == true)
    }
}

final class LogBufferTests: XCTestCase {
    func testJoinsChunksSplitMidLineAndNormalisesCRLF() {
        var b = LogBuffer()
        b.append("first line\r\nsecond ")
        XCTAssertEqual(b.lines, ["first line"])
        b.append("line\r\nthird")
        XCTAssertEqual(b.lines, ["first line", "second line"])
        XCTAssertEqual(b.text, "first line\nsecond line\nthird", "unfinished last line is still shown")
        b.append(" part\r\n")
        XCTAssertEqual(b.lines.last, "third part")
    }

    func testDropsSSHClosedNoticeAndCapsLines() {
        var b = LogBuffer(maxLines: 3)
        b.append("a\nb\nc\nd\nConnection to hetzner closed.\r\n")
        XCTAssertEqual(b.lines, ["b", "c", "d"])
    }

    func testLogsCommandMatchesSpecAndValidatesID() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        let script = commands.first { $0["id"] as? String == "docker_logs" }?["script"] as? String
        XCTAssertEqual(script, "docker logs -f --tail 100 {id}")
        XCTAssertEqual(DockerSession.logsCommand(id: "abcdef012345"), "docker logs -f --tail 100 abcdef012345")
        XCTAssertNil(DockerSession.logsCommand(id: "abcdef012345 && reboot"))
    }
}

final class LogLineParserTests: XCTestCase {
    func testLevels() {
        typealias P = LogLineParser
        XCTAssertEqual(P.level(of: #"2026/10/10 00:20:05.642147 [error] dnsproxy: exchange failed err="unexpected EOF""#), .error)
        XCTAssertEqual(P.level(of: #"{"level":"info","time":"2026-10-09T20:39:12Z","msg":"removed 13 streams"}"#), .info)
        XCTAssertEqual(P.level(of: #"time=2026-10-09T21:00:04Z level=WARN source=x msg="slow""#), .warn)
        XCTAssertEqual(P.level(of: "17:50:41 WARN Retrying indexer (2/3)"), .warn)
        XCTAssertEqual(P.level(of: "17:51:12 ERROR Database is locked"), .error)
        XCTAssertEqual(P.level(of: "level: debug starting"), .debug)
        XCTAssertEqual(P.level(of: "[trace] noisy"), .debug)
        XCTAssertEqual(P.level(of: "[FATAL] gone"), .error)
    }

    func testProseIsNotGuessed() {
        typealias P2 = LogLineParser
        XCTAssertNil(P2.level(of: "no error occurred, nothing to warn about"))
        XCTAssertNil(P2.level(of: "GET /api/info 200"))
        XCTAssertNil(P2.level(of: ""))
        XCTAssertEqual(P2.level(of: #"{"level":"info","msg":"an error was handled"}"#), .info, "explicit level beats words in the message")
    }

    func testTimestampLength() {
        XCTAssertEqual(LogLineParser.timestampLength(in: "2026-10-09T20:39:12.454Z INFO x"), 24)
        XCTAssertEqual(LogLineParser.timestampLength(in: "2026/10/10 00:20:05.642147 [error]"), 26)
        XCTAssertEqual(LogLineParser.timestampLength(in: "17:51:12 ERROR Database"), 8)
        XCTAssertEqual(LogLineParser.timestampLength(in: "no timestamp here"), 0)
        XCTAssertEqual(LogLineParser.timestampLength(in: "level=info time=2026-10-09T20:39:12Z"), 0, "only a leading timestamp")
    }
}

final class LogBufferCountTests: XCTestCase {
    func testTotalAppendedKeepsCountingAfterTheBufferIsFull() {
        var b = LogBuffer(maxLines: 3)
        b.append("a\nb\nc\nd\ne\n")
        XCTAssertEqual(b.lines, ["c", "d", "e"])
        XCTAssertEqual(b.totalAppended, 5)
        b.append("f\npartial")
        XCTAssertEqual(b.totalAppended, 6, "an unfinished line is not counted until it ends")
        b.append("ial\nConnection to host closed.\n")
        XCTAssertEqual(b.totalAppended, 7, "the finished partial line counts; ssh's own closing notice does not")
    }
}
