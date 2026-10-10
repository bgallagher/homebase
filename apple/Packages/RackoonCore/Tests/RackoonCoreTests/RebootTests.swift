import Foundation
import XCTest
@testable import RackoonCore

final class SystemInfoParserTests: XCTestCase {
    private func overview(_ name: String) throws -> Overview {
        try OverviewParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/overview/\(name).out.txt"), encoding: .utf8))
    }

    func testSystemFieldsAndModelName() throws {
        let o = try overview("ubuntu-24.04")
        XCTAssertEqual(o.modelName, "Hetzner vServer")
        XCTAssertEqual(o.machineID.count, 32)
        XCTAssertEqual(o.kernel, "6.8.0-146-generic")
        XCTAssertEqual(o.serverTime, 1791615000)
        XCTAssertEqual(o.timeZoneName, "UTC")
    }

    func testMissingDMIAndANonUTCZone() throws {
        let o = try overview("synthetic-no-dmi-offset-zone")
        XCTAssertEqual(o.modelName, "", "no vendor or product reported")
        XCTAssertEqual(o.utcOffsetSeconds, -(5 * 3600 + 30 * 60))
        XCTAssertEqual(o.timeZoneName, "IST")
    }

    func testOldOutputWithoutASystemSectionStillParses() throws {
        var text = try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
        let a = try XCTUnwrap(text.range(of: "##system\n")), b = try XCTUnwrap(text.range(of: "##reboot\n"))
        text.removeSubrange(a.lowerBound..<b.lowerBound)
        let o = try OverviewParser.parse(text)
        XCTAssertEqual(o.bootID, "")
        XCTAssertEqual(o.serverTime, 0)
        XCTAssertEqual(o.hostname.isEmpty, false)
    }

    func testCommandsMatchSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func script(_ id: String) -> String? { commands.first { $0["id"] as? String == id }?["script"] as? String }
        XCTAssertEqual(RebootSession.bootIDCommand, script("boot_id"))
        XCTAssertEqual(RebootSession.rebootCommand, script("reboot"))
        XCTAssertEqual(ServerSession.overviewCommand, script("overview"))
    }
}

final class RebootSessionTests: XCTestCase {
    private func ok(_ out: String) -> Result<CommandResult, Error> { .success(CommandResult(stdout: out)) }
    private let down: Result<CommandResult, Error> = .success(CommandResult(stdout: "", stderr: "ssh: connect to host: Connection refused", exitCode: 255))

    func testRebootNeedsConfirmationAndHonoursReadOnly() async throws {
        let t = FakeTransport([])
        let session = RebootSession(transport: t)
        do { try await session.reboot(confirmation: nil); XCTFail() } catch { XCTAssertEqual(error as? PolicyError, .notConfirmed) }
        let ro = RebootSession(transport: t, policy: ActionPolicy(readOnly: true))
        XCTAssertThrowsError(try ro.confirm()) { XCTAssertEqual($0 as? PolicyError, .readOnly) }
        XCTAssertTrue(t.commands.isEmpty, "nothing was sent")
    }

    func testReadsTheBootIDThenSchedulesTheReboot() async throws {
        let t = FakeTransport([ok("aaa-111\n"), ok("##rebooting\n")])
        let session = RebootSession(transport: t)
        try await session.reboot(confirmation: try session.confirm())
        XCTAssertEqual(t.commands, [RebootSession.bootIDCommand, RebootSession.rebootCommand])
    }

    func testNoSudoIsExplainedAndNothingIsWaitedFor() async throws {
        let t = FakeTransport([ok("aaa\n"), .success(CommandResult(stdout: "##no-sudo\n", exitCode: 5))])
        let session = RebootSession(transport: t)
        do { try await session.reboot(confirmation: try session.confirm()); XCTFail() }
        catch { XCTAssertEqual(error as? RebootError, .noSudo) }
        let outcome = await session.waitForReturn(timeout: 5, interval: 0, sleep: { _ in })
        XCTAssertEqual(outcome, .timedOut, "no reboot was scheduled, so there is nothing to wait for")
    }

    func testWaitsThroughDowntimeAndTheOldSystemUntilTheBootIDChanges() async throws {
        let t = FakeTransport([ok("aaa\n"), ok("##rebooting\n"),
                               ok("aaa\n"),      // still the old system for a moment
                               down, down,       // going down, then booting
                               ok("bbb\n")])     // back, new boot
        let session = RebootSession(transport: t)
        try await session.reboot(confirmation: try session.confirm())
        let clock = Clock()
        let outcome = await session.waitForReturn(timeout: 600, interval: 4, now: { clock.now }, sleep: { clock.advance($0) })
        guard case .back(let elapsed) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(elapsed, 0)
        XCTAssertEqual(t.commands.filter { $0 == RebootSession.bootIDCommand }.count, 5, "1 before + 4 polls")
    }

    func testTimesOutIfTheServerNeverComesBack() async throws {
        let t = FakeTransport([ok("aaa\n"), ok("##rebooting\n"), down])
        let session = RebootSession(transport: t)
        try await session.reboot(confirmation: try session.confirm())
        let clock = Clock()
        let outcome = await session.waitForReturn(timeout: 60, interval: 4, now: { clock.now }, sleep: { clock.advance($0) })
        XCTAssertEqual(outcome, .timedOut)
    }

    /// A manual clock so the polling loop runs instantly.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date()
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }
}
