import Foundation
import XCTest
@testable import RackoonCore

final class StackRemovalLabelsTests: XCTestCase {
    /// A stack as `docker ps` reports it for the hello stack on the real server (compose labels only).
    func testFolderDeletionIsOfferedForAStackReadFromDockerLabels() throws {
        let row = #"{"ID":"39a63766f536","Names":"hello-hello-1","Image":"nginxdemos/hello:latest","State":"running","Status":"Up 5 minutes","Ports":"100.125.183.84:8080->80/tcp","Labels":"com.docker.compose.project=hello,com.docker.compose.project.working_dir=/opt/stacks/hello,com.docker.compose.project.config_files=/opt/stacks/hello/compose.yaml,com.docker.compose.service=hello"}"#
        let stack = try XCTUnwrap(DockerParser.parse("##docker\nok\n##ps\n\(row)\n##stats\n").stacks.first)
        XCTAssertNil(StackRemoval.folderProblem(for: stack))
        let command = try XCTUnwrap(StackRemoval(deleteFolder: true).command(for: stack))
        XCTAssertTrue(command.hasPrefix("cd '/opt/stacks/hello' && docker compose -p hello -f '/opt/stacks/hello/compose.yaml' down --remove-orphans && cd / && { [ -f '/opt/stacks/hello/compose.yaml' ] || {"), command)
        XCTAssertTrue(command.contains("rm -rf -- '/opt/stacks/hello'"), command)
    }
}
