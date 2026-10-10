import Foundation
import XCTest
@testable import RackoonCore

final class OverviewTests: XCTestCase {
    /// Every fixture in spec/fixtures/overview must parse to its expected JSON (shared with the Kotlin core).
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/overview")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") }
        XCTAssertFalse(outs.isEmpty)
        for out in outs {
            let expectedURL = URL(fileURLWithPath: out.path.replacingOccurrences(of: ".out.txt", with: ".expected.json"))
            let parsed = try OverviewParser.parse(String(contentsOf: out, encoding: .utf8))
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed)) as? NSDictionary
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? NSDictionary
            XCTAssertEqual(actual, expected, out.lastPathComponent)
        }
    }

    /// The Swift command string must stay identical to spec/commands.json.
    func testCommandMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let commands = json["commands"] as! [[String: Any]]
        let script = commands.first { $0["id"] as? String == "overview" }?["script"] as? String
        XCTAssertEqual(ServerSession.overviewCommand, script)
    }

    func testMissingSectionThrows() {
        XCTAssertThrowsError(try OverviewParser.parse("##hostname\nx\n")) {
            XCTAssertEqual($0 as? ParseError, .missingSection("os"))
        }
    }

    func testCPUPercentFromTwoReadings() throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
        let a = try OverviewParser.parse(text)
        var b = a
        b.cpu = .init(total: a.cpu.total + 1000, idle: a.cpu.idle + 750) // 25% busy
        XCTAssertEqual(try XCTUnwrap(b.cpuPercent(since: a)), 25, accuracy: 0.001)
        XCTAssertNil(a.cpuPercent(since: a))
    }

    func testAttentionRules() throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
        var o = try OverviewParser.parse(text)
        XCTAssertTrue(Attention.evaluate(o).isEmpty)

        o.disks[0].usePercent = 85
        XCTAssertTrue(Attention.evaluate(o).isEmpty, "threshold is strictly over 85")
        o.disks[0].usePercent = 91
        o.rebootRequired = true
        let items = Attention.evaluate(o)
        XCTAssertEqual(items.map(\.id), ["disk_high:/", "reboot_required"])
        XCTAssertEqual(items[0].severity, .warning)
        o.disks[0].usePercent = 96
        XCTAssertEqual(Attention.evaluate(o)[0].severity, .critical)

        o.disks[0].usePercent = 10
        o.rebootRequired = false
        o.unhealthyContainers = ["sonarr", "radarr"]
        let unhealthy = Attention.evaluate(o)
        XCTAssertEqual(unhealthy.map(\.id), ["container_unhealthy:sonarr", "container_unhealthy:radarr"])
        XCTAssertEqual(unhealthy[0].message, "sonarr is unhealthy.")
        XCTAssertEqual(unhealthy[0].fix, "docker")
    }
}

final class ServerSessionTests: XCTestCase {
    private func fixture() throws -> String {
        try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
    }

    func testRefreshPublishesStateAndComputesCPUOnSecondReading() async throws {
        let first = try fixture()
        // Second reading: same counters but 1000 more idle ticks, so CPU use over the interval is 0%.
        let second = first.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("cpu  ") else { return String(line) }
            var f = line.split(separator: " ").map(String.init)
            f[4] = String(Int(f[4])! + 1000)
            return f.joined(separator: " ")
        }.joined(separator: "\n")
        XCTAssertNotEqual(first, second)
        let session = ServerSession(transport: FakeTransport([
            .success(CommandResult(stdout: first)), .success(CommandResult(stdout: second)),
        ]))
        await session.refresh()
        var state = await session.state
        XCTAssertEqual(state.overview?.hostname, "ubuntu-4gb-hel1-1")
        XCTAssertNil(state.cpuPercent, "needs two readings")
        XCTAssertNil(state.error)

        await session.refresh()
        state = await session.state
        XCTAssertEqual(try XCTUnwrap(state.cpuPercent), 0, accuracy: 0.001) // only idle grew
    }

    func testFailureKeepsLastGoodDataAndReportsError() async throws {
        let session = ServerSession(transport: FakeTransport([
            .success(CommandResult(stdout: try fixture())),
            .success(CommandResult(stdout: "", stderr: "Connection refused", exitCode: 255)),
        ]))
        await session.refresh()
        await session.refresh()
        let state = await session.state
        XCTAssertNotNil(state.overview)
        XCTAssertEqual(state.error, "Connection refused")
    }
}
