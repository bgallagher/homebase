import Foundation
import XCTest
@testable import RackoonCore

final class UnraidTests: XCTestCase {
    /// Every fixture in spec/fixtures/unraid must parse to its expected JSON. Error fixtures expect {"error": "..."}.
    /// Run with RACKOON_WRITE_GOLDEN=1 to write any missing expected file, then review it before committing.
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/unraid")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") && !$0.lastPathComponent.hasPrefix("raw-") }
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(outs.count, 3)
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
            let snapshot = try UnraidParser.parse(text)
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! NSDictionary
        } catch UnraidParseError.notUnraid {
            return ["error": "notUnraid"]
        } catch {
            return ["error": "other", "message": "\(error)"]
        }
    }

    private func fixture(_ name: String) throws -> UnraidSnapshot {
        try UnraidParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/unraid/\(name).out.txt"), encoding: .utf8))
    }

    func testCommandMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(UnraidSession.command, commands.first { $0["id"] as? String == "unraid" }?["script"] as? String)
    }

    func testDetectsUnraidFromOSRelease() {
        XCTAssertEqual(ServerKind.detect(.init(id: "unraid-os", name: "Unraid OS", version: "7.3.3", prettyName: "Unraid OS 7.3 x86_64")), .unraid)
        XCTAssertEqual(ServerKind.detect(.init(id: "slackware", name: "Unraid", version: "6.11", prettyName: "Unraid 6.11")), .unraid)
        XCTAssertEqual(ServerKind.detect(.init(id: "ubuntu", name: "Ubuntu", version: "24.04", prettyName: "Ubuntu 24.04 LTS")), .server)
        XCTAssertEqual(ServerKind.unraid.hiddenScreens, ["updates"], "Unraid has no apt")
        XCTAssertTrue(ServerKind.server.hiddenScreens.isEmpty)
    }

    func testRealZFSArray() throws {
        let s = try fixture("unraid-7.3-zfs")
        XCTAssertEqual(s.version, "7.3.3")
        XCTAssertTrue(s.array.isStarted)
        XCTAssertNil(s.array.operation, "mdResync=0 means idle even though mdResyncAction keeps the last action")
        XCTAssertEqual(s.parityDisks.map(\.name), ["parity", "parity2"])
        XCTAssertEqual(s.dataDisks.map(\.name), ["disk1", "disk2", "disk3", "disk4"])
        XCTAssertEqual(s.dataDisks.first?.model, "ST12000VN0007-2GS116", "the serial is not shown")
        XCTAssertEqual(s.dataDisks.first?.filesystem?.type, "zfs")
        // disks.ini is in KiB: disk2 holds 8617119520 KiB of 11576279040.
        XCTAssertEqual(s.dataDisks[1].filesystem?.usedBytes, 8_617_119_520 * 1024)
        XCTAssertEqual(s.dataDisks[1].filesystem?.usePercent, 74)
        XCTAssertGreaterThan(s.arrayTotalBytes, 40_000_000_000_000)
        let pools = s.pools
        XCTAssertEqual(pools.map(\.name), ["cache"])
        XCTAssertEqual(pools.first?.devices.map(\.name), ["cache", "cache2"], "cache2 is a member, not a pool of its own")
        XCTAssertEqual(pools.first?.health, "ONLINE")
        XCTAssertEqual(s.flash?.filesystem?.mount, "/boot")
        XCTAssertEqual(s.cpuTemperature, 63, "Intel package temperature")
        XCTAssertEqual(s.spinningFans.count, 3)
        XCTAssertFalse(s.boardSensors.contains { $0.celsius < -40 }, "the -128 °C non-reading is dropped")
        XCTAssertEqual(s.boardSensors.filter { $0.name == "Memory" }.count, 1, "two DIMM sensors collapse into one row")
        XCTAssertEqual(s.shares.count, 17)
        XCTAssertEqual(s.parityChecks.count, 10)
        XCTAssertEqual(s.lastParityCheck?.label, "Parity check")
        XCTAssertEqual(s.parityChecks[3].label, "Rebuilding disk 3")
        XCTAssertFalse(s.parityChecks[2].completed, "exit -4 is a cancelled check")
        XCTAssertEqual(s.parityChecks[1].finished, "2025 Nov 8 14:10:41", "the log's double space before a one-digit day is folded")
        XCTAssertNotNil(s.parityChecks[1].finishedDate(utcOffsetSeconds: 0))
        XCTAssertEqual(UnraidAttention.evaluate(s), [], "a healthy array needs no attention")
    }

    func testRunningCheckDisabledDiskAndAttention() throws {
        let s = try fixture("synthetic-check-running-disabled")
        let op = try XCTUnwrap(s.array.operation)
        XCTAssertEqual(op.label, "Parity check")
        XCTAssertEqual(op.fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(op.bytesPerSecond), 1_000_000 / 10 * 1024, accuracy: 1)
        XCTAssertNotNil(op.remainingSeconds)
        XCTAssertEqual(s.parityDisks.map(\.name), ["parity"], "an empty parity2 slot is not a disk")
        XCTAssertEqual(s.dataDisks.map(\.name), ["disk1", "disk2", "disk3"], "an empty disk4 slot is not a disk")
        XCTAssertNil(s.dataDisks[1].temperature, "spun down: no reading, never a wake-up")
        XCTAssertTrue(s.dataDisks[1].spunDown)
        XCTAssertEqual(s.pools.first?.filesystem?.profile, "raid1")
        XCTAssertNil(s.pools.first?.health, "not ZFS")
        XCTAssertEqual(s.cpuTemperature, 58.25, "AMD Tctl")
        XCTAssertEqual(s.spinningFans.map(\.label), ["fan1"])
        XCTAssertEqual(s.shares.first { $0.name == "appdata" }?.placement, "cache, then array")
        XCTAssertEqual(s.shares.first { $0.name == "isos" }?.placement, "array")

        let ids = Set(UnraidAttention.evaluate(s).map(\.id))
        XCTAssertTrue(ids.contains("array_disabled"))
        XCTAssertTrue(ids.contains("disk_status:disk3"))
        XCTAssertTrue(ids.contains("disk_errors:disk2"))
        XCTAssertTrue(ids.contains("disk_hot:disk1"), "47 °C is over a hard drive's 45 °C warning")
        XCTAssertTrue(ids.contains("disk_hot:cache2"), "72 °C is over an SSD's 70 °C limit")
        XCTAssertTrue(ids.contains("disk_full:disk1"), "95% full")
        XCTAssertTrue(ids.contains("parity_errors"))
        XCTAssertFalse(ids.contains { $0.contains("disk4") || $0.contains("parity2") }, "empty slots raise nothing")
        XCTAssertEqual(UnraidAttention.evaluate(s).first { $0.id == "disk_hot:cache2" }?.severity, .critical)
    }

    func testNotUnraid() {
        XCTAssertThrowsError(try fixture("synthetic-not-unraid")) { XCTAssertEqual($0 as? UnraidParseError, .notUnraid) }
    }

    func testDescribeActions() {
        XCTAssertEqual(UnraidSnapshot.describe("check P Q"), "Parity check")
        XCTAssertEqual(UnraidSnapshot.describe("recon P"), "Parity sync")
        XCTAssertEqual(UnraidSnapshot.describe("recon D5"), "Rebuilding disk 5")
        XCTAssertEqual(UnraidSnapshot.describe("clear"), "Clearing disk")
    }

    func testSessionKeepsLastSnapshotOnFailure() async throws {
        let good = try String(contentsOf: specDir.appendingPathComponent("fixtures/unraid/unraid-7.3-zfs.out.txt"), encoding: .utf8)
        let session = UnraidSession(transport: FakeTransport([
            .success(CommandResult(stdout: good)),
            .success(CommandResult(stdout: "", stderr: "Connection refused", exitCode: 255)),
        ]))
        var state = await session.refresh()
        XCTAssertEqual(state.snapshot?.dataDisks.count, 4)
        state = await session.refresh()
        XCTAssertEqual(state.snapshot?.dataDisks.count, 4, "old data stays visible")
        XCTAssertEqual(state.error, "Connection refused")
    }
}
