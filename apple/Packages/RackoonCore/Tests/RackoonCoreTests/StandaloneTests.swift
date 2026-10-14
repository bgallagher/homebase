import Foundation
import XCTest
@testable import RackoonCore

final class StandaloneStackTests: XCTestCase {
    private func container(_ name: String, project: String? = nil, image: String = "nginx:1.27", id: String = "abcdef012345") -> DockerContainer {
        DockerContainer(id: id, name: name, image: image, state: "running", health: "none", status: "Up", ports: [],
                        project: project, service: project == nil ? nil : "web",
                        workingDir: project.map { "/srv/\($0)" }, configFile: project.map { "/srv/\($0)/compose.yaml" })
    }

    func testEveryStandaloneContainerGetsItsOwnStackWithAUniqueID() {
        let snapshot = DockerSnapshot(containers: [
            container("Portainer", id: "111111111111"),
            container("media-web-1", project: "media", id: "222222222222"),
            container("adguard", id: "333333333333"),
            container("media", id: "444444444444"),   // a standalone container named like a compose project
        ])
        let stacks = snapshot.stacks
        XCTAssertEqual(stacks.map(\.name), ["adguard", "media", "media", "Portainer"], "by name ignoring case; compose first on a tie")
        XCTAssertEqual(stacks.map(\.isStandalone), [true, false, true, true])
        XCTAssertEqual(stacks.map(\.id), ["standalone/adguard", "media", "standalone/media", "standalone/Portainer"])
        XCTAssertEqual(Set(stacks.map(\.id)).count, stacks.count, "ids never clash")
        XCTAssertTrue(stacks.filter(\.isStandalone).allSatisfy { $0.containers.count == 1 })
        XCTAssertEqual(stacks.map(\.kindLabel), ["Standalone", "Compose Stack", "Standalone", "Standalone"])
    }

    func testAContainerKnowsWhichStackItIsShownIn() {
        XCTAssertEqual(DockerStack.id(of: container("media-web-1", project: "media")), "media")
        XCTAssertEqual(DockerStack.id(of: container("adguard")), "standalone/adguard")
    }

    func testTheOrderDoesNotDependOnDockersListingOrder() {
        let a = container("media", id: "444444444444"), b = container("media-web-1", project: "media", id: "222222222222")
        XCTAssertEqual(DockerSnapshot(containers: [a, b]).stacks.map(\.id), DockerSnapshot(containers: [b, a]).stacks.map(\.id))
    }

    func testComposeActionsStillRefuseStandaloneStacks() throws {
        let stack = try XCTUnwrap(DockerSnapshot(containers: [container("adguard")]).stacks.first)
        for action in ComposeAction.allCases { XCTAssertNil(action.command(for: stack), action.rawValue) }
        XCTAssertNil(StackRemoval().command(for: stack))
        XCTAssertNil(StackFiles.editable(for: stack))
    }
}

final class StandaloneActionTests: XCTestCase {
    private func stack(image: String = "nginx:1.27", id: String = "abcdef012345", standalone: Bool = true, name: String = "adguard") -> DockerStack {
        let c = DockerContainer(id: id, name: name, image: image, state: "running", health: "none", status: "Up", ports: [])
        return DockerStack(name: name, workingDir: nil, configFile: nil, configFiles: [], containers: [c], isStandalone: standalone)
    }

    func testTemplatesMatchSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func spec(_ id: String) -> [String: Any]? { commands.first { $0["id"] as? String == id } }
        XCTAssertEqual(spec(StandaloneAction.pullCommandID)?["script"] as? String, StandaloneAction.pullTemplate)
        XCTAssertEqual(spec(StandaloneAction.removeCommandID)?["script"] as? String, StandaloneAction.removeTemplate)
        XCTAssertEqual(spec(StandaloneAction.pullCommandID)?["kind"] as? String, "action")
        XCTAssertEqual(spec(StandaloneAction.removeCommandID)?["kind"] as? String, "action")
    }

    func testCommandsAreExact() {
        XCTAssertEqual(StandaloneAction.pullImage.command(for: stack()), "docker pull 'nginx:1.27'")
        XCTAssertEqual(StandaloneAction.pullImage.command(for: stack(image: "ghcr.io/org/app@sha256:" + String(repeating: "a", count: 64))),
                       "docker pull 'ghcr.io/org/app@sha256:\(String(repeating: "a", count: 64))'")
        XCTAssertEqual(StandaloneAction.remove(volumes: false).command(for: stack()), "docker rm -f abcdef012345")
        XCTAssertEqual(StandaloneAction.remove(volumes: true).command(for: stack()), "docker rm -f -v abcdef012345")
        XCTAssertEqual(StandaloneAction.remove(volumes: true).intent(for: stack())?.summary, "Delete container adguard and its anonymous volumes")
        XCTAssertEqual(StandaloneAction.pullImage.intent(for: stack())?.risk, .mutate)
    }

    func testOnlyAStandaloneStackOfOneContainerIsAccepted() {
        XCTAssertNil(StandaloneAction.pullImage.command(for: stack(standalone: false)))
        XCTAssertNil(StandaloneAction.remove(volumes: false).command(for: stack(standalone: false)))
        var two = stack()
        two.containers.append(two.containers[0])
        XCTAssertNil(StandaloneAction.remove(volumes: false).command(for: two))
    }

    func testUnsafeOrUnpullableValuesAreRefused() {
        for bad in ["", "-flag", "nginx; reboot", "nginx $(id)", "a'b", "nginx\nreboot", "sha256:" + String(repeating: "a", count: 64),
                    "abcdef012345", String(repeating: "b", count: 64), "ünïcode"] {
            XCTAssertNil(StandaloneAction.pullImage.command(for: stack(image: bad)), bad.debugDescription)
        }
        for bad in ["abc", "ABCDEF012345", "abcdef012345; rm -rf /", "$(whoami)abcdef"] {
            XCTAssertNil(StandaloneAction.remove(volumes: false).command(for: stack(id: bad)), bad)
        }
        XCTAssertNotNil(StandaloneAction.pullImage.command(for: stack(image: "registry.local:5000/team/app:v1.2_rc-3")))
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ActionStreamEvent] = []
        func add(_ e: ActionStreamEvent) { lock.withLock { items.append(e) } }
        var events: [ActionStreamEvent] { lock.withLock { items } }
    }

    func testStreamsUnderTheStackIDAndNeedsAConfirmation() async throws {
        let snapshot = try String(contentsOf: specDir.appendingPathComponent("fixtures/docker/ubuntu-24.04-compose.out.txt"), encoding: .utf8)
        let t = FakeTransport([.success(CommandResult(stdout: snapshot))])
        t.streamChunks = ["1.27: Pulling from library/nginx\r\n", "\r\n##rackoon-exit:0\r\n"]
        let session = DockerSession(transport: t)
        let got = Collector()

        await session.performStreaming(.pullImage, stack: stack(), confirmation: nil, cols: 80, rows: 24, onEvent: { got.add($0) })
        XCTAssertTrue(t.streamedCommands.isEmpty, "nothing runs without a confirmation")
        XCTAssertEqual(got.events, [.finished(exitCode: nil)])

        let confirmation = try session.confirm(.pullImage, stack: stack())
        await session.performStreaming(.pullImage, stack: stack(), confirmation: confirmation, cols: 80, rows: 24, onEvent: { got.add($0) })
        XCTAssertEqual(t.streamedCommands, [StreamedCommand.wrap("docker pull 'nginx:1.27'", cols: 80, rows: 24)])
        XCTAssertEqual(got.events.last, .finished(exitCode: 0))
        let state = await session.state
        XCTAssertNil(state.actionError)
        XCTAssertTrue(state.busy.isEmpty && state.busyStacks.isEmpty)

        XCTAssertThrowsError(try session.confirm(.remove(volumes: false), stack: stack(standalone: false)), "a compose stack is not deleted with docker rm")
        XCTAssertThrowsError(try DockerSession(transport: t, policy: ActionPolicy(readOnly: true)).confirm(.remove(volumes: false), stack: stack()))
    }
}

final class StackSummaryTests: XCTestCase {
    private func container(_ n: Int, state: String = "running", health: String = "none") -> DockerContainer {
        DockerContainer(id: String(format: "%012x", n), name: "app-s\(n)-1", image: "img", state: state, health: health, status: "", ports: [],
                        project: "app", service: "s\(n)")
    }
    private func stack(_ cs: [DockerContainer]) -> DockerStack {
        DockerStack(name: "app", workingDir: nil, configFile: nil, configFiles: [], containers: cs, isStandalone: false)
    }

    func testFourOrFewerAreAllShown() {
        let s = stack((1...4).map { container($0) })
        XCTAssertEqual(s.summaryContainers().shown.map(\.service), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(s.summaryContainers().hidden, 0)
    }

    func testMoreThanFourShowsFourInTheStacksOrderAndCountsTheRest() {
        let s = stack((1...9).map { container($0) })
        XCTAssertEqual(s.summaryContainers().shown.map(\.service), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(s.summaryContainers().hidden, 5)
    }

    func testProblemsAreNeverTheOnesLeftOut() {
        var cs = (1...7).map { container($0) }
        cs[6] = container(7, health: "unhealthy")
        cs[5] = container(6, state: "exited")
        let shown = stack(cs).summaryContainers().shown.map(\.service)
        XCTAssertEqual(shown, ["s1", "s2", "s6", "s7"], "unhealthy and stopped are kept, still listed in the stack's order")
        XCTAssertEqual(stack(cs).summaryContainers().hidden, 3)
    }
}
