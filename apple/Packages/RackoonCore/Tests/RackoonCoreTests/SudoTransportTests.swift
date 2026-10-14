import Foundation
import XCTest
@testable import RackoonCore

final class SudoTransportTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private func sudo(_ t: FakeTransport, until: Date = .distantFuture, flag: Flag = Flag()) -> SudoTransport {
        SudoTransport(base: t, password: "hunter2", validUntil: until, onRejected: { flag.hit() })
    }

    func testRunWrapsTheWholeCommandAndSendsThePasswordOnStdinOnly() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: "##docker\nok\n"))])
        let result = try await sudo(t).run(DockerSession.command, timeout: 20)
        XCTAssertEqual(result.stdout, "##docker\nok\n")
        XCTAssertEqual(t.commands, [try XCTUnwrap(SudoTransport.elevated(DockerSession.command))])
        XCTAssertTrue(t.commands[0].hasPrefix("sudo -S -p '' sh -c '"))
        XCTAssertEqual(t.inputs, ["hunter2\n"])
        XCTAssertFalse(t.commands[0].contains("hunter2"), "never in the command")
    }

    /// `sh -c '<quoted>'` must hand the inner shell exactly the original script: checked through a real /bin/sh.
    func testTheQuotedScriptReachesTheInnerShellUnchanged() throws {
        for script in [DockerSession.command, #"cd '/srv/it'"s' && docker compose -p a up -d"#, "echo \"$HOME\" '$x' `id`"] {
            let quoted = try XCTUnwrap(ShellQuote.quote(script))
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf '%s' " + quoted]
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), script)
        }
    }

    func testOnlySudosOwnRefusalLocks() async throws {
        let flag = Flag()
        let registry = FakeTransport([.success(CommandResult(stdout: "", stderr: "unauthorized: authentication required\n", exitCode: 1))])
        let r = try await sudo(registry, flag: flag).run("docker pull x", timeout: 20)
        XCTAssertEqual(r.exitCode, 1, "the command's own failure is just a failure")
        XCTAssertEqual(flag.count, 0)
        let wrong = FakeTransport([.success(CommandResult(stdout: "", stderr: "sudo: Authentication failed, try again.\nsudo: Authentication required but not attempted\n", exitCode: 1))])
        do { _ = try await sudo(wrong, flag: flag).run("docker ps", timeout: 20); XCTFail() }
        catch { XCTAssertEqual(error as? SudoTransportError, .rejected) }
        XCTAssertEqual(flag.count, 1)
        let classic = FakeTransport([.success(CommandResult(stdout: "", stderr: "Sorry, try again.\nsudo: 1 incorrect password attempt\n", exitCode: 1))])
        do { _ = try await sudo(classic, flag: flag).run("docker ps", timeout: 20); XCTFail() }
        catch { XCTAssertEqual(error as? SudoTransportError, .rejected) }
    }

    func testNothingIsSentOnceTheWindowIsOver() async {
        let t = FakeTransport([])
        do { _ = try await sudo(t, until: Date().addingTimeInterval(-1)).run("docker ps", timeout: 20); XCTFail() }
        catch { XCTAssertEqual(error as? SudoTransportError, .locked) }
        XCTAssertTrue(t.commands.isEmpty)
        XCTAssertTrue(t.inputs.isEmpty)
    }

    func testStreamsAnswerOnePromptAndHideTheHandshake() async throws {
        let nonce = "0123456789abcdef0123456789abcdef"
        let t = FakeTransport([])
        t.streamChunks = ["[sudo: ##rackoon-sudo-\(nonce):] Password: ****\r\n", "##rackoon-sudo-ok-\(nonce)\r\n",
                          "web-1  | started\r\n", "##rackoon-sudo-\(nonce):\r\n"]   // the last one is a log line: ignored
        let flag = Flag()
        let s = SudoTransport(base: t, password: "hunter2", validUntil: .distantFuture, makeNonce: { nonce }, onRejected: { flag.hit() })
        var shown = ""
        for try await chunk in s.stream("docker logs -f --tail 100 abcdef012345") { shown += chunk }
        let typed = await t.typedIntoStream()
        XCTAssertEqual(typed, ["hunter2\n"])
        XCTAssertEqual(shown, "web-1  | started\r\n##rackoon-sudo-\(nonce):\r\n", "no prompt, no asterisks, no notice in the logs")
        let sent = try XCTUnwrap(t.streamedCommands.last)
        XCTAssertTrue(sent.contains("sudo -p '##rackoon-sudo-\(nonce):' -v"))
        XCTAssertTrue(sent.hasSuffix("sudo -n sh -c 'docker logs -f --tail 100 abcdef012345'"))
        XCTAssertFalse(sent.contains("hunter2"))
        XCTAssertEqual(flag.count, 0)
    }

    func testAStreamWithAWrongPasswordLocks() async {
        let nonce = "0123456789abcdef0123456789abcdef"
        let t = FakeTransport([])
        t.streamChunks = ["##rackoon-sudo-\(nonce):\r\n", "sudo: Authentication failed, try again.\r\n", "##rackoon-sudo-\(nonce):"]
        let flag = Flag()
        let s = SudoTransport(base: t, password: "wrong", validUntil: .distantFuture, makeNonce: { nonce }, onRejected: { flag.hit() })
        do { for try await _ in s.stream("docker ps") {}; XCTFail() } catch { XCTAssertEqual(error as? SudoTransportError, .rejected) }
        XCTAssertEqual(flag.count, 1)
    }

    func testCommandsThatCanNotBeOneWordAreRefused() async {
        do { _ = try await sudo(FakeTransport([])).run("echo a\necho b", timeout: 5); XCTFail() }
        catch { XCTAssertEqual(error as? SudoTransportError, .cannotElevate) }
    }
}
