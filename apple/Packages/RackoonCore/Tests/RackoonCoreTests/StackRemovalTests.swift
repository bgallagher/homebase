import Foundation
import XCTest
@testable import RackoonCore

final class StackRemovalTests: XCTestCase {
    private func stack(dir: String = "/opt/stacks/media", files: [String]? = nil, standalone: Bool = false, name: String = "media") -> DockerStack {
        let f = files ?? [dir + "/compose.yaml"]
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none", status: "Up",
                                ports: [], project: name, service: "web", workingDir: dir, configFile: f.first, configFiles: f)
        return DockerStack(name: name, workingDir: dir, configFile: f.first, configFiles: f, containers: [c], isStandalone: standalone)
    }

    func testTemplateMatchesSpecAndCommandsAreExact() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(StackRemoval.template, commands.first { $0["id"] as? String == "compose_down" }?["script"] as? String)
        let base = "cd '/opt/stacks/media' && docker compose -p media -f '/opt/stacks/media/compose.yaml' down --remove-orphans"
        XCTAssertEqual(StackRemoval().command(for: stack()), base)
        XCTAssertEqual(StackRemoval(removeVolumes: true).command(for: stack()), base + " -v")
        XCTAssertEqual(StackRemoval(deleteFolder: true).command(for: stack()),
                       base + " && cd / && [ -f '/opt/stacks/media/compose.yaml' ] && rm -rf -- '/opt/stacks/media'")
        XCTAssertEqual(StackRemoval(removeVolumes: true, deleteFolder: true).intent(for: stack())?.summary, "Delete stack media and its folder")
        XCTAssertEqual(StackRemoval().intent(for: stack())?.risk, .mutate)
    }

    func testFolderDeletionIsRefusedForSystemAndHomeFolders() {
        for dir in ["/", "/opt", "/home", "/home/brian", "/root", "/var", "/var/lib", "/var/lib/docker", "/usr/local", "/etc", "/tmp", "/srv",
                    "/opt/../etc", "/opt/./x", "/opt//x", "/opt/stacks/"] {
            let s = stack(dir: dir, files: [dir.hasSuffix("/") ? dir + "compose.yaml" : dir + "/compose.yaml"])
            XCTAssertNotNil(StackRemoval.folderProblem(for: s), dir)
            XCTAssertNil(StackRemoval(deleteFolder: true).command(for: s), dir)
        }
        for dir in ["/opt/stacks/media", "/opt/media", "/srv/media", "/home/brian/stacks/media", "/mnt/data/stacks/x"] {
            XCTAssertNil(StackRemoval.folderProblem(for: stack(dir: dir)), dir)
        }
        // A compose file outside the folder, or an unknown folder: no folder deletion, but plain removal is still fine.
        let outside = stack(files: ["/opt/stacks/media/compose.yaml", "/etc/other.yaml"])
        XCTAssertNotNil(StackRemoval.folderProblem(for: outside))
        XCTAssertNil(StackRemoval(deleteFolder: true).command(for: outside))
        XCTAssertNotNil(StackRemoval(removeVolumes: true).command(for: outside))
    }

    func testStandaloneAndUnsafeProjectsAreRefused() {
        XCTAssertNil(StackRemoval().command(for: stack(standalone: true)))
        XCTAssertNil(StackRemoval().command(for: stack(name: "media; reboot")))
        XCTAssertNil(StackRemoval().command(for: stack(dir: "relative", files: ["relative/compose.yaml"])))
    }

    func testRemovalNeedsConfirmationAndHonoursReadOnly() throws {
        let policy = ActionPolicy()
        let session = DockerSession(transport: FakeTransport([]), policy: policy)
        XCTAssertNoThrow(try session.confirm(StackRemoval(), stack: stack()))
        XCTAssertThrowsError(try session.confirm(StackRemoval(deleteFolder: true), stack: stack(dir: "/opt")))
        policy.isReadOnly = true
        XCTAssertThrowsError(try session.confirm(StackRemoval(), stack: stack()))
    }

    // MARK: the real command under /bin/sh with a stub `docker`

    private func run(_ removal: StackRemoval, dir: URL, dockerExit: Int32) throws -> Int32 {
        let bin = dir.deletingLastPathComponent().appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let stub = bin.appendingPathComponent("docker")
        try "#!/bin/sh\nexit \(dockerExit)\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let s = stack(dir: dir.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", try XCTUnwrap(removal.command(for: s))]
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin"]
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    func testFolderIsDeletedOnlyAfterDownSucceedsAndOnlyWithItsComposeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rk-del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String, compose: Bool) throws -> URL {
            let d = root.appendingPathComponent("stacks/\(name)")
            try FileManager.default.createDirectory(at: d.appendingPathComponent("data"), withIntermediateDirectories: true)
            try "x".write(to: d.appendingPathComponent("data/file"), atomically: true, encoding: .utf8)
            if compose { try "services: {}".write(to: d.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8) }
            return d
        }
        let ok = try make("ok", compose: true)
        XCTAssertEqual(try run(StackRemoval(deleteFolder: true), dir: ok, dockerExit: 0), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ok.path), "folder with its data is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("stacks").path), "the parent is untouched")

        let failing = try make("failing", compose: true)
        XCTAssertNotEqual(try run(StackRemoval(deleteFolder: true), dir: failing, dockerExit: 1), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failing.appendingPathComponent("data/file").path), "down failed: nothing deleted")

        let noCompose = try make("nocompose", compose: false)
        XCTAssertNotEqual(try run(StackRemoval(deleteFolder: true), dir: noCompose, dockerExit: 0), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: noCompose.appendingPathComponent("data/file").path), "no compose file: folder is not emptied")

        let keep = try make("keep", compose: true)
        XCTAssertEqual(try run(StackRemoval(), dir: keep, dockerExit: 0), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.appendingPathComponent("compose.yaml").path), "plain removal keeps the files")
    }
}
