import XCTest
@testable import RackoonCore

final class FleetTests: XCTestCase {
    private func overview(_ name: String) throws -> Overview {
        try OverviewParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/overview/\(name).out.txt"), encoding: .utf8))
    }

    private func docker(_ name: String) throws -> DockerSnapshot {
        try DockerParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/docker/\(name).out.txt"), encoding: .utf8))
    }

    private func state(_ o: Overview?, cpu: Double? = nil, error: String? = nil, stale: Bool = false) -> ServerState {
        var s = ServerState()
        s.overview = o
        s.cpuPercent = cpu
        s.error = error
        s.isStale = stale
        return s
    }

    func testSamplesComeOnlyFromRealChecks() throws {
        let o = try overview("ubuntu-24.04")
        let at = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(HealthSample(state: state(nil), at: at), "nothing read yet")
        XCTAssertNil(HealthSample(state: state(o, stale: true), at: at), "a cached snapshot is not a check")
        XCTAssertEqual(HealthSample(state: state(o, error: "timed out"), at: at)?.up, false)
        let up = try XCTUnwrap(HealthSample(state: state(o, cpu: 12), at: at))
        XCTAssertTrue(up.up)
        XCTAssertEqual(up.cpuPercent, 12)
        XCTAssertEqual(up.memoryFraction, o.memory.usedFraction)
        XCTAssertEqual(up.diskFraction, o.disks.map { Double($0.usePercent) / 100 }.max())
    }

    func testHistoryKeepsAboutOneSampleAMinuteButEveryChange() {
        var h = HealthHistory()
        let t0 = Date(timeIntervalSince1970: 0)
        h.record(HealthSample(at: t0, up: true))
        h.record(HealthSample(at: t0.addingTimeInterval(5), up: true))       // the selected server's next poll: skipped
        XCTAssertEqual(h.samples.count, 1)
        h.record(HealthSample(at: t0.addingTimeInterval(10), up: false))     // went down: kept at once
        h.record(HealthSample(at: t0.addingTimeInterval(15), up: true))      // came back: kept at once
        h.record(HealthSample(at: t0.addingTimeInterval(80), up: true))      // a minute on: kept
        XCTAssertEqual(h.samples.map(\.up), [true, false, true, true])
        XCTAssertEqual(h.uptimeFraction, 0.75)
        XCTAssertEqual(h.downCount, 1)
        XCTAssertNil(HealthHistory().uptimeFraction)
        for i in 0..<200 { h.record(HealthSample(at: t0.addingTimeInterval(1000 + Double(i) * 60), up: true)) }
        XCTAssertEqual(h.samples.count, HealthHistory.capacity, "an hour of minutes, oldest dropped")
        XCTAssertEqual(h.uptimeFraction, 1)
    }

    func testFleetTotals() throws {
        let a = try overview("ubuntu-24.04"), b = try overview("synthetic-security-updates")
        let t = FleetTotals.of([state(a, cpu: 10), state(b, cpu: 40, error: "Connection refused"), state(nil)])
        XCTAssertEqual(t.servers, 3)
        XCTAssertEqual(t.online, 1, "an erroring server is not online; one with no reading neither")
        XCTAssertEqual(t.memoryTotal, a.memory.totalBytes + b.memory.totalBytes, "last known numbers still count")
        XCTAssertEqual(t.diskTotal, (a.disks + b.disks).map(\.totalBytes).reduce(0, +))
        XCTAssertEqual(t.updates, a.pendingUpdates + b.pendingUpdates)
        XCTAssertEqual(t.securityUpdates, a.securityUpdates + b.securityUpdates)
        let expected = (10 * Double(a.cores) + 40 * Double(b.cores)) / Double(a.cores + b.cores)
        XCTAssertEqual(try XCTUnwrap(t.cpuPercent), expected, accuracy: 0.0001, "weighted by cores")
        XCTAssertNil(FleetTotals.of([state(a)]).cpuPercent, "no second reading yet")
    }

    func testDockerTotalsAndDataDisk() throws {
        let snapshot = try docker("synthetic-mixed-states")
        let o = try overview("ubuntu-24.04")
        let t = DockerTotals.of(snapshot, host: o)
        XCTAssertEqual(t.containers, snapshot.containers.count)
        XCTAssertEqual(t.running, snapshot.containers.filter(\.isRunning).count)
        XCTAssertEqual(t.unhealthy, 1)
        XCTAssertEqual(t.stacks, 4)
        XCTAssertNotNil(t.dataDisk)

        func disk(_ mount: String) -> Overview.Disk {
            Overview.Disk(filesystem: "/dev/x", mount: mount, totalBytes: 100, usedBytes: 50, usePercent: 50)
        }
        let disks = [disk("/"), disk("/var"), disk("/var/lib/docker2"), disk("/mnt/data")]
        XCTAssertEqual(DockerTotals.disk(holding: "/var/lib/docker", in: disks)?.mount, "/var", "longest mount that really contains it")
        XCTAssertEqual(DockerTotals.disk(holding: "/var/lib/docker", in: [disk("/"), disk("/mnt/data")])?.mount, "/")
        XCTAssertEqual(DockerTotals.disk(holding: "/var/lib/docker", in: [disk("/var/lib/docker")])?.mount, "/var/lib/docker")
        XCTAssertNil(DockerTotals.disk(holding: "/var/lib/docker", in: [disk("/mnt/data")]))
    }

    func testMainWebPort() throws {
        let stacks = try docker("synthetic-mixed-states").stacks
        func port(_ name: String) -> Int? { stacks.first { $0.name == name }?.mainWebPort }
        XCTAssertEqual(port("shlink"), 8087, "published 8087 -> container 8080")
        XCTAssertNil(port("dockge"), "5001 is not a usual web port")
        XCTAssertNil(port("monitoring"), "prometheus' 9090 is not a web front end")
        let streams = try XCTUnwrap(try docker("synthetic-bookmarks").stacks.first { $0.name == "streams" })
        XCTAssertEqual(streams.mainWebPort, 8080, "the bookmark has no port, container port 80 is published on 8080")
        XCTAssertEqual(streams.publishedPorts, [8080])
    }
}
