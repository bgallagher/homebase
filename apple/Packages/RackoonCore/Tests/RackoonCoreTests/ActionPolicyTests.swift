import Foundation
import XCTest
@testable import RackoonCore

final class ActionPolicyTests: XCTestCase {
    private let id = "abcdef012345"

    func testReadsAlwaysPassEvenInReadOnlyMode() throws {
        let policy = ActionPolicy(readOnly: true)
        let read = Intent(summary: "List", command: "docker ps", risk: .read)
        XCTAssertNoThrow(try policy.authorize(read, with: nil))
        XCTAssertNoThrow(try policy.confirm(read))
    }

    func testMutationNeedsAMatchingConfirmation() throws {
        let policy = ActionPolicy()
        let restart = try XCTUnwrap(DockerAction.restart.intent(containerID: id))
        let stop = try XCTUnwrap(DockerAction.stop.intent(containerID: id))
        XCTAssertThrowsError(try policy.authorize(restart, with: nil)) { XCTAssertEqual($0 as? PolicyError, .notConfirmed) }
        // A confirmation for one command cannot be reused for another.
        let confirmedStop = try policy.confirm(stop)
        XCTAssertThrowsError(try policy.authorize(restart, with: confirmedStop)) { XCTAssertEqual($0 as? PolicyError, .notConfirmed) }
        XCTAssertNoThrow(try policy.authorize(stop, with: confirmedStop))
    }

    func testReadOnlyBlocksNewAndAlreadyMintedConfirmations() throws {
        let policy = ActionPolicy()
        let intent = try XCTUnwrap(DockerAction.stop.intent(containerID: id))
        let confirmation = try policy.confirm(intent)
        policy.isReadOnly = true
        XCTAssertThrowsError(try policy.confirm(intent)) { XCTAssertEqual($0 as? PolicyError, .readOnly) }
        XCTAssertThrowsError(try policy.authorize(intent, with: confirmation)) { XCTAssertEqual($0 as? PolicyError, .readOnly) }
        policy.isReadOnly = false
        XCTAssertNoThrow(try policy.authorize(intent, with: confirmation))
    }

    func testDockerActionIsBlockedInReadOnlyModeAndNothingIsSent() async throws {
        let transport = FakeTransport([])
        let policy = ActionPolicy(readOnly: true)
        let session = DockerSession(transport: transport, policy: policy)
        XCTAssertThrowsError(try session.confirm(.stop, containerID: id))
        await session.perform(.stop, containerID: id, confirmation: nil)
        XCTAssertTrue(transport.commands.isEmpty)
        let error = await session.state.actionError
        XCTAssertEqual(error, PolicyError.readOnly.errorDescription)
    }

    func testDockerActionWithoutConfirmationIsRefused() async {
        let transport = FakeTransport([])
        let session = DockerSession(transport: transport)
        await session.perform(.restart, containerID: id, confirmation: nil)
        XCTAssertTrue(transport.commands.isEmpty)
        let error = await session.state.actionError
        XCTAssertEqual(error, PolicyError.notConfirmed.errorDescription)
    }

    func testInvalidContainerIDCannotBeConfirmed() {
        let session = DockerSession(transport: FakeTransport([]))
        XCTAssertThrowsError(try session.confirm(.stop, containerID: "x; reboot")) { XCTAssertEqual($0 as? PolicyError, .invalidTarget) }
    }
}
