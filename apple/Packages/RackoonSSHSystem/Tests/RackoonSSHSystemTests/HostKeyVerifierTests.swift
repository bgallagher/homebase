import XCTest
@testable import RackoonSSHSystem

final class HostKeyVerifierTests: XCTestCase {
    func testClassify() {
        typealias V = HostKeyVerifier
        XCTAssertEqual(V.classify(exitCode: 0, stderr: ""), .trusted)
        XCTAssertEqual(V.classify(exitCode: 255, stderr: "Host key verification failed.\n"), .unknownKey)
        XCTAssertEqual(V.classify(exitCode: 255, stderr: """
            @@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@
            Host key verification failed.
            """), .changedKey, "a changed key must win over the generic failure line")
        XCTAssertEqual(V.classify(exitCode: 255, stderr: "root@host: Permission denied (publickey).\n"), .trusted)
        XCTAssertEqual(V.classify(exitCode: 255, stderr: "ssh: Could not resolve hostname x\n"),
                       .other("ssh: Could not resolve hostname x"))
        XCTAssertEqual(V.classify(exitCode: 255, stderr: ""), .other("ssh exited with code 255"))
    }
}
