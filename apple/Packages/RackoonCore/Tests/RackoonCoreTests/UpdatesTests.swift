import Foundation
import XCTest
@testable import RackoonCore

final class UpdatesParserTests: XCTestCase {
    /// Every fixture in spec/fixtures/updates must parse to its expected JSON (shared with the Kotlin core).
    /// Error fixtures expect {"error": "..."}.
    /// Run with RACKOON_WRITE_GOLDEN=1 to write any missing expected file, then review it before committing.
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/updates")
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
            let snapshot = try UpdatesParser.parse(text)
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! NSDictionary
        } catch UpdatesParseError.notInstalled {
            return ["error": "notInstalled"]
        } catch {
            return ["error": "other", "message": "\(error)"]
        }
    }

    func testSecurityIsDecidedBySuiteNotPackageName() throws {
        let snapshot = try UpdatesParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/updates/synthetic-debian-minimal.out.txt"), encoding: .utf8))
        XCTAssertEqual(snapshot.packages.map(\.name), ["curl", "bash", "foo-security-tools"])
        XCTAssertEqual(snapshot.packages.map(\.isSecurity), [true, false, false])
        XCTAssertEqual(snapshot.securityCount, 1)
        XCTAssertNil(snapshot.packages[1].oldVersion, "a line without 'upgradable from' still parses")
    }

    func testSecurityPendingFixtureCounts() throws {
        let snapshot = try UpdatesParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/updates/synthetic-security-pending.out.txt"), encoding: .utf8))
        XCTAssertEqual(snapshot.packages.count, 6)
        XCTAssertEqual(snapshot.securityCount, 3, "openssl, libssl3t64 and the infra-security client")
        XCTAssertEqual(snapshot.held, ["linux-image-generic", "docker-ce"])
        XCTAssertTrue(snapshot.rebootRequired)
        XCTAssertEqual(snapshot.packages.first?.oldVersion, "3.0.13-0ubuntu3.4")
    }

    func testMissingAptSectionIsMalformed() {
        XCTAssertThrowsError(try UpdatesParser.parse("##held\n")) {
            XCTAssertEqual($0 as? UpdatesParseError, .malformed("no ##apt section"))
        }
    }

    func testCommandMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(UpdatesSession.command, commands.first { $0["id"] as? String == "updates" }?["script"] as? String)
    }

    func testSessionKeepsLastGoodSnapshotWhenARefreshFails() async throws {
        let good = try String(contentsOf: specDir.appendingPathComponent("fixtures/updates/synthetic-security-pending.out.txt"), encoding: .utf8)
        let session = UpdatesSession(transport: FakeTransport([
            .success(CommandResult(stdout: good)),
            .success(CommandResult(stdout: "", stderr: "Connection refused", exitCode: 255)),
        ]))
        var state = await session.refresh()
        XCTAssertEqual(state.snapshot?.securityCount, 3)
        XCTAssertNil(state.error)
        state = await session.refresh()
        XCTAssertEqual(state.snapshot?.securityCount, 3, "old data stays visible")
        XCTAssertEqual(state.error, "Connection refused")
    }

    func testAptMissingIsReported() async {
        let out = (try? String(contentsOf: specDir.appendingPathComponent("fixtures/updates/synthetic-apt-missing.out.txt"), encoding: .utf8)) ?? ""
        let session = UpdatesSession(transport: FakeTransport([.success(CommandResult(stdout: out))]))
        let state = await session.refresh()
        XCTAssertEqual(state.error, "apt is not installed on this server.")
        XCTAssertNil(state.snapshot)
    }
}
