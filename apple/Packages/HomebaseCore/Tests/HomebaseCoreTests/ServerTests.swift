import Foundation
import XCTest
@testable import HomebaseCore

final class SSHConfigParserTests: XCTestCase {
    func testParsesConcreteHostsAndSkipsWildcards() {
        let hosts = SSHConfigParser.parse("""
            # my servers
            Host hetzner
                HostName 203.0.113.7
                User root
                Port 2222
                IdentityFile ~/.ssh/id_ed25519

            Host nas nas-local
              HostName=192.168.1.20
              User admin

            Host *
                ServerAliveInterval 30

            Host *.internal !bad
                User nobody

            Match host foo
                User ignored

            Host last
            """)
        XCTAssertEqual(hosts.map(\.alias), ["hetzner", "nas", "nas-local", "last"])
        XCTAssertEqual(hosts[0], SSHConfigHost(alias: "hetzner", hostName: "203.0.113.7", user: "root", port: 2222))
        XCTAssertEqual(hosts[1].hostName, "192.168.1.20", "Key=value form")
        XCTAssertEqual(hosts[2].user, "admin", "one block can define several aliases")
        XCTAssertNil(hosts[3].hostName)
    }

    func testImportKeepsAliasAsHostSoSSHAppliesTheRestOfTheEntry() {
        let s = SSHConfigHost(alias: "hetzner", hostName: "203.0.113.7", user: "root", port: 2222).asServer()
        XCTAssertEqual(s.host, "hetzner")
        XCTAssertEqual(s.sshConfigAlias, "hetzner")
        XCTAssertNil(s.user)
        XCTAssertEqual(s.sshDestination, "hetzner")
    }
}

final class ServerStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("homebase-test-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testServersRoundTripAndEmptyStoreIsEmpty() throws {
        let store = ServerStore(directory: dir)
        XCTAssertEqual(store.loadServers(), [])
        let servers = [Server(name: "vps", host: "vps.example.com", user: "root", port: 2222),
                       Server(name: "nas", host: "nas", sshConfigAlias: "nas")]
        try store.saveServers(servers)
        XCTAssertEqual(store.loadServers(), servers)
    }

    func testCorruptServersFileLoadsAsEmptyInsteadOfCrashing() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("servers.json"))
        XCTAssertEqual(ServerStore(directory: dir).loadServers(), [])
    }

    func testSnapshotRoundTripAndDelete() throws {
        let store = ServerStore(directory: dir)
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
        let overview = try OverviewParser.parse(text)
        XCTAssertNil(store.loadSnapshot(serverID: "a"))
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try store.saveSnapshot(overview, serverID: "a", at: when)
        let loaded = try XCTUnwrap(store.loadSnapshot(serverID: "a"))
        XCTAssertEqual(loaded.overview, overview)
        XCTAssertEqual(loaded.savedAt, when)
        store.deleteSnapshot(serverID: "a")
        XCTAssertNil(store.loadSnapshot(serverID: "a"))
    }
}

final class ServerModelTests: XCTestCase {
    func testSSHDestination() {
        XCTAssertEqual(Server(name: "a", host: "h").sshDestination, "h")
        XCTAssertEqual(Server(name: "a", host: "h", user: "root").sshDestination, "root@h")
        XCTAssertEqual(Server(name: "a", host: "h", user: "").sshDestination, "h", "empty user is ignored")
    }

    func testOldServerJSONWithoutUserOrPortStillDecodes() throws {
        let old = #"{"id":"1","name":"vps","host":"vps.example.com"}"#
        let s = try JSONDecoder().decode(Server.self, from: Data(old.utf8))
        XCTAssertNil(s.user)
        XCTAssertNil(s.port)
    }
}

final class CachedSessionTests: XCTestCase {
    func testCachedOverviewShowsAsStaleUntilFirstPollThenPersists() async throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
        let cached = try OverviewParser.parse(text)
        let saved = SavedBox()
        let session = ServerSession(
            transport: FakeTransport([.success(CommandResult(stdout: text))]),
            cached: (cached, Date(timeIntervalSince1970: 1)),
            onSnapshot: { saved.set($0) })

        var state = await session.state
        XCTAssertTrue(state.isStale)
        XCTAssertEqual(state.overview, cached, "instant paint from the cache")

        await session.refresh()
        state = await session.state
        XCTAssertFalse(state.isStale)
        XCTAssertNotNil(saved.value, "a successful poll is persisted")
    }

    func testFailedFirstPollKeepsStaleCacheVisible() async throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
        let cached = try OverviewParser.parse(text)
        let session = ServerSession(
            transport: FakeTransport([.success(CommandResult(stdout: "", stderr: "timeout", exitCode: 255))]),
            cached: (cached, Date()))
        await session.refresh()
        let state = await session.state
        XCTAssertTrue(state.isStale)
        XCTAssertEqual(state.error, "timeout")
        XCTAssertNotNil(state.overview)
    }
}

private final class SavedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Overview?
    func set(_ v: Overview) { lock.lock(); _value = v; lock.unlock() }
    var value: Overview? { lock.lock(); defer { lock.unlock() }; return _value }
}
