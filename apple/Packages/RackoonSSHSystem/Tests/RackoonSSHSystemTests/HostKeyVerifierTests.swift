import XCTest
import RackoonCore
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
        XCTAssertEqual(V.classify(exitCode: 255, stderr: "root@host: Permission denied (publickey).\n"),
                       .authFailed("root@host: Permission denied (publickey)."),
                       "the host key was checked before the login, so this is a login problem, not a trust one")
        XCTAssertEqual(V.classify(exitCode: 255, stderr: """
            Permissions 0644 for '/Users/me/.ssh/loose' are too open.
            Load key "/Users/me/.ssh/loose": bad permissions
            root@host: Permission denied (publickey).
            """), .authFailed("root@host: Permission denied (publickey)."), "only the verdict line is the message")
        XCTAssertEqual(V.classify(exitCode: 255, stderr: "ssh: Could not resolve hostname x\n"),
                       .other("ssh: Could not resolve hostname x"))
        XCTAssertEqual(V.classify(exitCode: 255, stderr: ""), .other("ssh exited with code 255"))
    }
}

final class OpenSSHArgumentsTests: XCTestCase {
    func testIdentityArgumentsOnlyWhenAKeyFileIsSet() {
        XCTAssertEqual(OpenSSHTransport.identityArguments(nil), [])
        XCTAssertEqual(OpenSSHTransport.identityArguments("  "), [])
        XCTAssertEqual(OpenSSHTransport.identityArguments("/keys/deploy"), ["-i", "/keys/deploy", "-o", "IdentitiesOnly=yes"])
        XCTAssertEqual(OpenSSHTransport.identityArguments("~/.ssh/deploy"),
                       ["-i", NSString(string: "~/.ssh/deploy").expandingTildeInPath, "-o", "IdentitiesOnly=yes"], "~ is expanded once, here")
    }

    func testTerminalArgumentsCarryTheKeyFileBeforeTheDestination() {
        let server = Server(name: "lab", host: "192.168.6.157", user: "lab", port: 2222, identityFile: "/keys/lab")
        let args = OpenSSHTransport.terminalArguments(for: server)
        XCTAssertEqual(args.suffix(5), ["-i", "/keys/lab", "-o", "IdentitiesOnly=yes", "lab@192.168.6.157"])
        XCTAssertTrue(args.contains("-p") && args.contains("2222"))
        XCTAssertFalse(OpenSSHTransport.terminalArguments(for: Server(name: "x", host: "x")).contains("-i"))
    }
}
