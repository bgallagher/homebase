import Foundation
import XCTest
@testable import RackoonCore

final class NewStackTests: XCTestCase {
    private func plan(name: String = "media", parent: String = "/opt/stacks", env: String = "") -> NewStackPlan {
        NewStackPlan(name: name, parentDirectory: parent, env: env)
    }

    func testTemplatesMatchSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func script(_ id: String) -> String? { commands.first { $0["id"] as? String == id }?["script"] as? String }
        XCTAssertEqual(NewStackCommands.checkTemplate, script("stack_new_check"))
        XCTAssertEqual(NewStackCommands.createTemplate, script("stack_create"))
    }

    func testPlanPathsAndValidation() {
        XCTAssertEqual(plan().directory, "/opt/stacks/media")
        XCTAssertEqual(plan(parent: "/opt/stacks/").directory, "/opt/stacks/media")
        XCTAssertEqual(plan(parent: "/").directory, "/media")
        XCTAssertEqual(plan().composePath, "/opt/stacks/media/compose.yaml")
        XCTAssertEqual(plan().stack?.workingDir, "/opt/stacks/media")
        XCTAssertNotNil(ComposeAction.up.command(for: plan().stack!))
        for bad in ["", "Media", "-x", "a b", "a/b", "a;reboot", "../x"] { XCTAssertNotNil(plan(name: bad).nameProblem, bad) }
        for bad in ["", "relative", "stacks", "/opt/../etc"] {
            XCTAssertNotNil(plan(parent: bad).folderProblem, bad)
            XCTAssertNil(plan(parent: bad).directory, bad)
        }
        XCTAssertNil(NewStackCommands.create(plan(name: "x; reboot")))
        XCTAssertNil(NewStackCommands.check(plan(name: "Bad")))
    }

    func testDefaultParentIsLearnedFromTheServer() {
        func stack(_ name: String, _ dir: String?, standalone: Bool = false) -> DockerStack {
            DockerStack(name: name, workingDir: dir, configFile: nil, configFiles: [], containers: [], isStandalone: standalone)
        }
        let stacks = [stack("a", "/opt/stacks/a"), stack("b", "/opt/stacks/b"), stack("c", "/srv/c"), stack("d", nil),
                      stack("e", "/mnt/x/e", standalone: true)]
        XCTAssertEqual(NewStackDefaults.parentDirectory(stacks: stacks, user: "root"), "/opt/stacks")
        // A tie goes to the shorter path, so the answer is stable.
        XCTAssertEqual(NewStackDefaults.parentDirectory(stacks: [stack("a", "/srv/long/a"), stack("b", "/opt/b")], user: nil), "/opt")
        XCTAssertEqual(NewStackDefaults.parentDirectory(stacks: [], user: "root"), "/opt/stacks")
        XCTAssertEqual(NewStackDefaults.parentDirectory(stacks: [], user: nil), "/opt/stacks")
        XCTAssertEqual(NewStackDefaults.parentDirectory(stacks: [], user: "brian"), "/home/brian/stacks")
    }

    func testIntentHasReadablePreviewAndIsAMutation() throws {
        let intent = try XCTUnwrap(NewStackSession(transport: FakeTransport([])).intent(for: plan(env: "A=1\n")))
        XCTAssertEqual(intent.risk, .mutate)
        let preview = try XCTUnwrap(intent.preview)
        XCTAssertTrue(preview.contains("Create folder /opt/stacks/media"))
        XCTAssertTrue(preview.contains(".env"))
        XCTAssertTrue(preview.contains("nginx:alpine"))
    }

    func testCreateNeedsConfirmationAndHonoursReadOnly() async throws {
        let policy = ActionPolicy()
        let transport = FakeTransport([])
        let session = NewStackSession(transport: transport, policy: policy)
        do { _ = try await session.create(plan(), confirmation: nil); XCTFail("ran without confirmation") } catch {}
        XCTAssertTrue(transport.commands.isEmpty)
        policy.isReadOnly = true
        XCTAssertThrowsError(try session.confirm(plan()))
    }

    // MARK: the real scripts under /bin/sh, with a stub `docker`

    private func runCreate(_ plan: NewStackPlan, dockerExit: Int32, in root: URL) throws -> (code: Int32, out: String) {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("docker")
        try "#!/bin/sh\n[ \"\(dockerExit)\" = 0 ] || echo 'yaml: line 3: bad' >&2\nexit \(dockerExit)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", try XCTUnwrap(NewStackCommands.create(plan))]
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    func testCreateWritesFilesAndRefusesAnExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rk-new-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = plan(parent: root.appendingPathComponent("stacks").path, env: "TOKEN=abc\n")
        let first = try runCreate(p, dockerExit: 0, in: root)
        XCTAssertEqual(first.code, 0, first.out)
        XCTAssertTrue(first.out.contains("##created"))
        let dir = try XCTUnwrap(p.directory)
        XCTAssertEqual(try String(contentsOfFile: dir + "/compose.yaml", encoding: .utf8), p.compose)
        XCTAssertEqual(try String(contentsOfFile: dir + "/.env", encoding: .utf8), "TOKEN=abc\n")
        let mode = try FileManager.default.attributesOfItem(atPath: dir + "/.env")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // Same name again: refused, and the first stack's files are untouched.
        let second = try runCreate(NewStackPlan(name: p.name, parentDirectory: p.parentDirectory, compose: "services: {}\n"), dockerExit: 0, in: root)
        XCTAssertEqual(second.code, 3)
        XCTAssertTrue(second.out.contains("##exists"))
        XCTAssertEqual(try String(contentsOfFile: dir + "/compose.yaml", encoding: .utf8), p.compose)
    }

    func testFailedCheckLeavesNothingBehind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rk-new-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = plan(parent: root.appendingPathComponent("stacks").path, env: "A=1\n")
        let result = try runCreate(p, dockerExit: 1, in: root)
        XCTAssertEqual(result.code, 4)
        XCTAssertTrue(result.out.contains("##invalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(p.directory)))
    }

    func testSimplifiesScratchPathsInIssues() {
        let issue = ComposeIssue(severity: .error, line: 3, message: "yaml: /tmp/tmp.AbC123/compose.yaml: bad; see /opt/stacks/x/.env")
        XCTAssertEqual(issue.simplifyingScratchPaths().message, "yaml: compose.yaml: bad; see .env")
    }
}
