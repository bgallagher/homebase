import Foundation
import XCTest
@testable import RackoonCore

final class AptActionTests: XCTestCase {
    private func specScript(_ id: String) throws -> String? {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        let entry = commands.first { $0["id"] as? String == id }
        XCTAssertEqual(entry?["kind"] as? String, "action")
        return entry?["script"] as? String
    }

    func testCommandsMatchSpec() throws {
        XCTAssertEqual(AptAction.refresh.command, try specScript("apt_refresh"))
        XCTAssertEqual(AptAction.upgradeAll.command, try specScript("apt_upgrade"))
        XCTAssertEqual(AptAction.upgrade(packages: ["pkg-a", "pkg-b"]).command,
                       try specScript("apt_upgrade_packages")?.replacingOccurrences(of: "{packages}", with: "pkg-a pkg-b"))
    }

    func testUpgradeListsPackagesAndNeverRemoves() throws {
        let c = try XCTUnwrap(AptAction.upgrade(packages: ["openssl", "libssl3t64", "g++-13"]).command)
        XCTAssertTrue(c.hasSuffix("install --only-upgrade -y -o Dpkg::Options::=--force-confold openssl libssl3t64 g++-13"))
        for action in [AptAction.refresh, .upgradeAll, .upgrade(packages: ["openssl"])] {
            let command = try XCTUnwrap(action.command)
            XCTAssertFalse(command.contains("dist-upgrade") || command.contains("remove") || command.contains("purge") || command.contains("autoremove"))
            XCTAssertTrue(command.contains("DEBIAN_FRONTEND=noninteractive"), "must never prompt")
            XCTAssertTrue(command.contains("sudo -n"), "must never ask for a password")
        }
    }

    func testDuplicatesAreRemovedAndTheListIsCapped() throws {
        let c = try XCTUnwrap(AptAction.upgrade(packages: ["openssl", "curl", "openssl"]).command)
        XCTAssertTrue(c.hasSuffix(" openssl curl"))
        let many = (0..<AptAction.maxPackages).map { "pkg-\($0)" }
        XCTAssertNotNil(AptAction.upgrade(packages: many).command)
        XCTAssertNil(AptAction.upgrade(packages: many + ["one-more"]).command)
        XCTAssertLessThan(try XCTUnwrap(AptAction.upgrade(packages: many).command).utf8.count, 8_000)
        XCTAssertTrue(try XCTUnwrap(AptAction.refresh.command).contains("LC_ALL=C"))
    }

    func testPackageNamesAreValidated() {
        for bad in ["", "a", "Openssl", "-o", "foo;reboot", "foo bar", "$(id)", "a\nb", "foo|bar", "a`b`", "ünï"] {
            XCTAssertNil(AptAction.upgrade(packages: [bad]).command, bad.debugDescription)
        }
        XCTAssertNil(AptAction.upgrade(packages: []).command)
        XCTAssertNil(AptAction.upgrade(packages: ["openssl", "x;y"]).command, "one bad name rejects the whole list")
        XCTAssertNotNil(AptAction.upgrade(packages: ["libstdc++6", "python3.12", "0ad"]).command)
    }

    /// The root/sudo prefix runs through a real /bin/sh with apt-get replaced by a stub on PATH.
    func testRealShellPicksSudoOnlyWhenNotRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rk-apt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func stub(_ name: String, _ body: String) throws {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("apt-get", "echo \"apt-get $*\"")
        try stub("sudo", "echo \"sudo $*\"; shift; shift; \"$@\"")   // sudo -n env ... apt-get ...
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", try XCTUnwrap(AptAction.refresh.command)]
        p.environment = ["PATH": dir.path + ":/usr/bin:/bin"]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if getuid() == 0 {
            XCTAssertEqual(out, "apt-get update\n")
        } else {
            XCTAssertTrue(out.contains("sudo -n env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update"), out)
        }
    }

    func testExplainsSudoAndLockFailures() {
        XCTAssertTrue(AptAction.explain(stderr: "sudo: a password is required", exitCode: 1).contains("passwordless sudo"))
        XCTAssertTrue(AptAction.explain(stderr: "E: Could not get lock /var/lib/dpkg/lock-frontend", exitCode: 100).contains("lock"))
        XCTAssertEqual(AptAction.explain(stderr: "a\nb\nc\nd", exitCode: 100), "b\nc\nd")
        // sudo's text is localised but always starts with "sudo:"; apt's real errors can arrive on stdout.
        XCTAssertTrue(AptAction.explain(stderr: "sudo: un mot de passe est nécessaire", exitCode: 1).contains("passwordless sudo"))
        XCTAssertTrue(AptAction.explain(stdout: "E: dpkg was interrupted, you must manually run 'dpkg --configure -a'", stderr: "", exitCode: 100).contains("dpkg --configure -a"))
        XCTAssertEqual(AptAction.explain(stdout: "noise\nE: Unable to correct problems, you have held broken packages.", stderr: "", exitCode: 100),
                       "E: Unable to correct problems, you have held broken packages.")
        XCTAssertEqual(AptAction.explain(stderr: "", exitCode: 7), "apt-get failed (exit 7)")
    }
}

final class UpdatesSessionActionTests: XCTestCase {
    private func read(_ name: String) throws -> String {
        try String(contentsOf: specDir.appendingPathComponent("fixtures/updates/\(name).out.txt"), encoding: .utf8)
    }

    func testRunsConfirmedActionThenRereadsTheList() async throws {
        let transport = FakeTransport([
            .success(CommandResult(stdout: "Reading package lists...\nDone\n")),
            .success(CommandResult(stdout: try read("ubuntu-24.04-current"))),
        ])
        let session = UpdatesSession(transport: transport)
        let action = AptAction.upgrade(packages: ["openssl"])
        await session.perform(action, confirmation: try session.confirm(action))
        XCTAssertEqual(transport.commands.first, action.command)
        XCTAssertEqual(transport.commands.count, 2, "action, then the update list")
        let state = await session.state
        XCTAssertFalse(state.isWorking)
        XCTAssertNil(state.actionError)
        XCTAssertEqual(state.actionOutput, "Reading package lists...\nDone")
        XCTAssertEqual(state.snapshot?.packages.count, 0)
    }

    func testNeedsConfirmationAndReadOnlyBlocks() async throws {
        let transport = FakeTransport([])
        let session = UpdatesSession(transport: transport)
        await session.perform(.upgradeAll, confirmation: nil)
        XCTAssertTrue(transport.commands.isEmpty)
        var error = await session.state.actionError
        XCTAssertEqual(error, PolicyError.notConfirmed.errorDescription)

        let readOnly = UpdatesSession(transport: transport, policy: ActionPolicy(readOnly: true))
        XCTAssertThrowsError(try readOnly.confirm(.refresh))
        await readOnly.perform(.refresh, confirmation: nil)
        XCTAssertTrue(transport.commands.isEmpty)
        error = await readOnly.state.actionError
        XCTAssertEqual(error, PolicyError.readOnly.errorDescription)
    }

    func testSudoFailureIsExplainedAndListStillRefreshes() async throws {
        let transport = FakeTransport([
            .success(CommandResult(stdout: "", stderr: "sudo: a password is required", exitCode: 1)),
            .success(CommandResult(stdout: try read("synthetic-security-pending"))),
        ])
        let session = UpdatesSession(transport: transport)
        await session.perform(.refresh, confirmation: try session.confirm(.refresh))
        let state = await session.state
        XCTAssertTrue(state.actionError?.contains("passwordless sudo") == true)
        XCTAssertEqual(state.snapshot?.securityCount, 3)
    }

    func testStaleOutputIsClearedWhenALaterActionIsRefused() async throws {
        let transport = FakeTransport([
            .success(CommandResult(stdout: "done\n")),
            .success(CommandResult(stdout: try read("ubuntu-24.04-current"))),
        ])
        let session = UpdatesSession(transport: transport)
        await session.perform(.refresh, confirmation: try session.confirm(.refresh))
        var state = await session.state
        XCTAssertEqual(state.actionOutput, "done")
        await session.perform(.upgradeAll, confirmation: nil)
        state = await session.state
        XCTAssertNil(state.actionOutput, "no 'done' beside a new error")
        XCTAssertNotNil(state.actionError)
    }

    func testInvalidPackageNameNeverRuns() async {
        let transport = FakeTransport([])
        let session = UpdatesSession(transport: transport)
        XCTAssertThrowsError(try session.confirm(.upgrade(packages: ["x; reboot"]))) { XCTAssertEqual($0 as? PolicyError, .invalidTarget) }
        await session.perform(.upgrade(packages: ["x; reboot"]), confirmation: nil)
        XCTAssertTrue(transport.commands.isEmpty)
    }
}
