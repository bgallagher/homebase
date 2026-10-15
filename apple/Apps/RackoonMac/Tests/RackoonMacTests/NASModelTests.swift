import Foundation
@testable import RackoonCore
import XCTest
@testable import RackoonMac

/// Replays canned command results, in order (the last one repeats).
private final class ReplayTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CommandResult]
    private(set) var runs = 0
    init(_ results: [CommandResult]) { self.results = results }

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock {
            runs += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor
final class NASModelTests: XCTestCase {
    private var good: String {
        get throws {
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { url.deleteLastPathComponent() }   // <repo>/apple/Apps/RackoonMac/Tests/RackoonMacTests/
            return try String(contentsOf: url.deletingLastPathComponent()
                .appendingPathComponent("spec/fixtures/unraid/unraid-7.3-zfs.out.txt"), encoding: .utf8)
        }
    }

    func testRefreshKeepsTheLastReadingWhenOneFails() async throws {
        let model = NASModel(transport: ReplayTransport([
            CommandResult(stdout: try good), CommandResult(stdout: "", stderr: "Connection timed out", exitCode: 255),
        ]))
        await model.refresh()
        XCTAssertEqual(model.snapshot?.dataDisks.count, 4)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.updatedAt)
        await model.refresh()
        XCTAssertEqual(model.snapshot?.dataDisks.count, 4, "the old reading stays on screen")
        XCTAssertEqual(model.error, "Connection timed out")
        XCTAssertFalse(model.loading)
    }

    func testNotUnraidIsExplained() async {
        let model = NASModel(transport: ReplayTransport([CommandResult(stdout: "##unraid\n##var\n")]))
        await model.refresh()
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.error, "This server does not look like Unraid (no /etc/unraid-version).")
    }

    func testPollStopsWithItsTask() async throws {
        let transport = ReplayTransport([CommandResult(stdout: try good)])
        let model = NASModel(transport: transport)
        let task = Task { await model.poll() }
        while transport.runs == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await task.value
        XCTAssertEqual(transport.runs, 1, "one read, then the 15 s wait is cancelled with the Overview")
    }

    func testStoreKeepsOneModelPerConnection() {
        var made = 0
        let store = NASStore { _ in made += 1; return NASModel(transport: ReplayTransport([CommandResult(stdout: "")])) }
        let server = Server(id: "s1", name: "nas", host: "192.168.1.10", user: "root")
        let first = store.model(for: server)
        XCTAssertTrue(store.model(for: server) === first, "switching screens keeps the reading")
        var renamed = server
        renamed.name = "renamed"
        XCTAssertTrue(store.model(for: renamed) === first, "a rename is not a new connection")
        var moved = server
        moved.host = "192.168.1.11"
        XCTAssertFalse(store.model(for: moved) === first, "a new address gets a new model")
        XCTAssertEqual(made, 2)
    }
}
