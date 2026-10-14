import Foundation
import XCTest
@testable import RackoonCore

private let nonce = "0123456789abcdef0123456789abcdef"
private let prompt = "##rackoon-sudo-\(nonce):"
private let ok = "##rackoon-sudo-ok-\(nonce)"
private let fail = "##rackoon-sudo-fail-\(nonce)"
/// sudo-rs (Ubuntu 26.04) over `ssh -tt`: the prompt is wrapped, typed characters echo as asterisks and are erased.
private let sudoRsPrompt = "[sudo: \(prompt)] Password: ****\u{8} \u{8}\u{8} \u{8}\u{8} \u{8}\u{8} \u{8}\r\n"

final class SudoElevationTests: XCTestCase {
    func testPasswordVariantIsThePrefixInFrontOfTheUnchangedScript() throws {
        let apt = try XCTUnwrap(AptAction.upgradeAll.command)
        let elevated = try XCTUnwrap(SudoElevation.withPassword(apt, nonce: nonce))
        XCTAssertTrue(elevated.hasSuffix(apt), "the script itself is untouched and still uses sudo -n")
        XCTAssertTrue(elevated.hasPrefix(#"if [ "$(id -u)" -ne 0 ]; then mesg n 2>/dev/null; stty -echo 2>/dev/null; sudo -p '\#(prompt)' -v"#),
                      "mesg n first: nobody else can write into the session to fake a prompt")
        XCTAssertNil(SudoElevation.withPassword("docker ps", nonce: nonce), "a script without $S has no password variant")
        XCTAssertNil(SudoElevation.withPassword(apt, nonce: "x'; reboot; '"), "a malformed nonce never reaches the shell")
        XCTAssertNotEqual(AptAction.refresh.passwordIntent(nonce: nonce), AptAction.refresh.intent, "its own intent and confirmation")
        XCTAssertEqual(AptAction.refresh.passwordIntent(nonce: nonce), AptAction.refresh.passwordIntent(nonce: nonce))
        XCTAssertNotEqual(AptAction.refresh.passwordIntent(nonce: nonce), AptAction.refresh.passwordIntent(nonce: SudoElevation.makeNonce()))
    }

    func testNoncesAreRandomHex() {
        let a = SudoElevation.makeNonce(), b = SudoElevation.makeNonce()
        XCTAssertTrue(SudoElevation.isNonce(a))
        XCTAssertNotEqual(a, b)
    }

    func testPrefixMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(SudoElevation.prefix, commands.first { $0["id"] as? String == "sudo_prompt" }?["script"] as? String)
    }

    /// The prefix through a real /bin/sh with a stub sudo: wrong password (stub exits 1) never runs the script and
    /// prints the fail marker with exit 7; a right one prints the ok marker, then the script runs.
    func testThePrefixInARealShell() throws {
        func run(stubExit: Int) throws -> (out: String, code: Int32) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rk-sudo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for (name, body) in [("sudo", "#!/bin/sh\necho \"sudo-args: $*\"\nexit \(stubExit)\n"), ("id", "#!/bin/sh\necho 1000\n")] {
                let f = dir.appendingPathComponent(name)
                try body.write(to: f, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", #"PATH="\#(dir.path):$PATH"; "# + SudoElevation.withPassword("S='sudo -n'; echo script-ran", nonce: nonce)!]
            let out = Pipe()
            p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return (String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), p.terminationStatus)
        }
        let good = try run(stubExit: 0)
        XCTAssertEqual(good.out, "sudo-args: -p \(prompt) -v\n\(ok)\nscript-ran\n")
        XCTAssertEqual(good.code, 0)
        let bad = try run(stubExit: 1)
        XCTAssertEqual(bad.out, "sudo-args: -p \(prompt) -v\n\(fail)\n")
        XCTAssertEqual(bad.code, 7)
    }

    func testRecognisesRefusalsFromClassicSudoAndSudoRs() {
        XCTAssertTrue(SudoElevation.needsPassword("sudo: a password is required\n"))
        XCTAssertTrue(SudoElevation.needsPassword("sudo: a terminal is required to read the password; either use the -S option"))
        XCTAssertTrue(SudoElevation.needsPassword("sudo: interactive authentication is required"), "sudo-rs, Ubuntu 26.04")
        XCTAssertFalse(SudoElevation.needsPassword("E: Could not get lock /var/lib/dpkg/lock-frontend"))
        XCTAssertTrue(SudoElevation.explainRefusal("lab is not in the sudoers file.").contains("not allowed to use sudo"))
        XCTAssertTrue(SudoElevation.isAuthFailure("sudo: 1 incorrect password attempt"))
        XCTAssertTrue(SudoElevation.isAuthFailure("sudo: Authentication failed, try again."))
        XCTAssertFalse(SudoElevation.isAuthFailure("Reading package lists... Done"))
        XCTAssertTrue(SudoElevation.explainRefusal("sudo: sorry, you must have a tty to run sudo").contains("terminal"))
    }
}

final class SudoHandshakeTests: XCTestCase {
    private func run(_ chunks: [String]) -> (shown: String, actions: [SudoHandshake.Action], outcome: SudoOutcome?) {
        var h = SudoHandshake(nonce: nonce)
        var shown = "", actions: [SudoHandshake.Action] = []
        for c in chunks { let r = h.push(c); shown += r.shown; actions += r.actions }
        shown += h.finish()
        return (shown, actions, h.outcome)
    }

    func testRightPasswordWithSudoRs() {
        let r = run([sudoRsPrompt, "\r\n", "\(ok)\r\n", "Reading package lists... Done\r\n"])
        XCTAssertEqual(r.actions, [.typePassword])
        XCTAssertEqual(r.outcome, .accepted)
        XCTAssertEqual(r.shown, SudoHandshake.notice + "\r\nReading package lists... Done\r\n")
        XCTAssertFalse(r.shown.contains("*"), "the password's length must not show")
    }

    func testRightPasswordWithClassicSudo() {
        let r = run([prompt, "\r\n", "\(ok)\r\n", "done\r\n"])
        XCTAssertEqual(r.actions, [.typePassword])
        XCTAssertEqual(r.outcome, .accepted)
        XCTAssertEqual(r.shown, SudoHandshake.notice + "done\r\n")
    }

    func testRootUserGetsTheOkMarkerWithoutAPrompt() {
        let r = run(["\(ok)\r\n", "output\r\n"])
        XCTAssertEqual(r.actions, [])
        XCTAssertEqual(r.outcome, .accepted)
        XCTAssertEqual(r.shown, "output\r\n")
    }

    func testWrongPasswordIsTypedOnceThenInterrupted() {
        let r = run([sudoRsPrompt, "sudo: Authentication failed, try again.\r\n", "[sudo: \(prompt)] Password: "])
        XCTAssertEqual(r.actions, [.typePassword, .interrupt], "never typed a second time")
        XCTAssertEqual(r.outcome, .rejected)
        XCTAssertTrue(r.shown.contains("Authentication failed"))
        XCTAssertTrue(r.shown.contains("not accepted"))
    }

    /// `Defaults passwd_tries=1` (or a PAM stack that stops at the first failure): sudo gives up without asking again.
    func testAWrongPasswordWithOneTryIsRejectedNotRefused() {
        let r = run([prompt, "\r\n", "sudo: 1 incorrect password attempt\r\n", "\(fail)\r\n"])
        XCTAssertEqual(r.actions, [.typePassword])
        XCTAssertEqual(r.outcome, .rejected, "so a stale saved password is forgotten instead of retried")
    }

    /// sudo-rs puts the marker in every hidden prompt, so a second-factor or password-change prompt also carries it.
    func testASecondQuestionWithoutAFailureIsNotAWrongPassword() {
        let r = run([sudoRsPrompt, "[sudo: \(prompt)] Verification code: "])
        XCTAssertEqual(r.actions, [.typePassword, .interrupt], "never answered, one Ctrl-C")
        XCTAssertEqual(r.outcome, .otherPrompt, "the password itself may be right: a saved one is kept")
        XCTAssertFalse(r.shown.contains("not accepted"))
    }

    func testRefusedForAnotherReasonCarriesWhatSudoSaid() {
        let r = run(["lab is not in the sudoers file.\r\n", "\(fail)\r\n"])
        XCTAssertEqual(r.actions, [])
        XCTAssertEqual(r.outcome, .refused("lab is not in the sudoers file."))
    }

    /// The attack from the review: text the script prints (a journal line, a user name) carrying a prompt marker after
    /// sudo has finished. Nothing may be typed, whatever it looks like.
    func testPromptsAfterTheOkMarkerAreNeverAnswered() {
        let r = run([prompt, "\r\n", "\(ok)\r\n", "Oct 13 sshd: Invalid user \(prompt) from 203.0.113.9\r\n",
                     "[sudo: \(prompt)] Password: \r\n", "sudo: Authentication failed, try again.\r\n"])
        XCTAssertEqual(r.actions, [.typePassword], "only the one prompt before the ok marker")
        XCTAssertEqual(r.outcome, .accepted, "words in the output don't change the outcome")
        XCTAssertTrue(r.shown.contains("Invalid user \(prompt)"), "after the handshake the output is shown as it is")
    }

    func testMarkersWithAnotherNonceAreJustText() {
        let other = "##rackoon-sudo-ffffffffffffffffffffffffffffffff:"
        let r = run(["\(other)\r\n", prompt, "\r\n", "\(ok)\r\n"])
        XCTAssertEqual(r.actions, [.typePassword])
        XCTAssertTrue(r.shown.hasPrefix(other))
    }

    func testHandshakeSplitAtEveryPoint() {
        let text = sudoRsPrompt + "\(ok)\r\nafter\r\n"
        let scalars = Array(text.unicodeScalars)
        for cut in 1..<scalars.count {
            let a = String(String.UnicodeScalarView(scalars[..<cut])), b = String(String.UnicodeScalarView(scalars[cut...]))
            let r = run([a, b])
            XCTAssertEqual(r.actions, [.typePassword], "cut at \(cut)")
            XCTAssertEqual(r.outcome, .accepted, "cut at \(cut)")
            XCTAssertEqual(r.shown, SudoHandshake.notice + "after\r\n", "cut at \(cut)")
        }
    }

    func testAStreamThatEndsEarlyIsUnfinished() {
        XCTAssertEqual(run(["Connection closed.\r\n"]).outcome, .unfinished)
    }
}

final class SudoStreamTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock(); private var parts: [String] = []
        func add(_ e: ActionStreamEvent) { if case .output(let s) = e { lock.withLock { parts.append(s) } } }
        var text: String { lock.withLock { parts.joined() } }
    }

    private let credential = SudoCredential(password: "hunter2", nonce: nonce)

    func testThePasswordIsTypedOnceAndNeverShown() async throws {
        let t = FakeTransport([])
        t.streamChunks = ["[sudo: \(prompt)] Password: ", "*******\r\n", "\(ok)\r\n", "Reading package lists... Done\r\n",
                          "\(prompt)\r\n",   // planted by the command's output: ignored
                          "\r\n##rackoon-exit:0\r\n"]
        let sink = Sink()
        let run = await StreamRunner.run(transport: t, command: "x", cols: 80, rows: 24, sudo: credential, onEvent: sink.add)
        let typed = await t.typedIntoStream()
        XCTAssertEqual(typed, ["hunter2\n"])
        XCTAssertEqual(run.sudo, .accepted)
        XCTAssertNil(run.sudoProblem)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertFalse(sink.text.contains("hunter2") || sink.text.contains("*") || run.text.contains("hunter2"))
    }

    func testAWrongPasswordIsTypedOnceThenInterrupted() async throws {
        let t = FakeTransport([])
        t.streamChunks = ["[sudo: \(prompt)] Password: ***\r\n", "sudo: Authentication failed, try again.\r\n",
                          "[sudo: \(prompt)] Password: "]
        let run = await StreamRunner.run(transport: t, command: "x", cols: 80, rows: 24, sudo: credential, onEvent: { _ in })
        let typed = await t.typedIntoStream()
        XCTAssertEqual(typed, ["hunter2\n", "\u{03}"], "never typed a second time: one Ctrl-C instead")
        XCTAssertTrue(run.sudoRejected)
        XCTAssertTrue(run.needsSudoPassword)
    }

    func testAuthenticationWordsInTheOutputNoLongerInterrupt() async throws {
        let t = FakeTransport([])
        t.streamChunks = ["\(prompt)\r\n", "\(ok)\r\n", "pam_unix(sshd:auth): authentication failed for root\r\n",
                          "Sorry, try again.\r\n", "\r\n##rackoon-exit:0\r\n"]
        let run = await StreamRunner.run(transport: t, command: "x", cols: 80, rows: 24, sudo: credential, onEvent: { _ in })
        let typed = await t.typedIntoStream()
        XCTAssertEqual(typed, ["hunter2\n"], "no Ctrl-C into a running apt because of a log line")
        XCTAssertEqual(run.sudo, .accepted)
        XCTAssertEqual(run.exitCode, 0)
    }

    func testASecondFactorPromptIsReportedAndNotRetried() async throws {
        let t = FakeTransport([])
        t.streamChunks = ["[sudo: \(prompt)] Password: \r\n", "[sudo: \(prompt)] Verification code: "]
        let run = await StreamRunner.run(transport: t, command: "x", cols: 80, rows: 24, sudo: credential, onEvent: { _ in })
        let typed = await t.typedIntoStream()
        XCTAssertEqual(typed, ["hunter2\n", "\u{03}"])
        XCTAssertEqual(run.sudo, .otherPrompt)
        XCTAssertFalse(run.needsSudoPassword, "asking for the password again would not help")
        XCTAssertEqual(run.sudoProblem, SudoElevation.otherPrompt)
    }

    func testSudoThatKeepsNoRecordIsReportedNotRetried() async {
        let t = FakeTransport([])
        t.streamChunks = ["\(prompt)\r\n", "\(ok)\r\n", "sudo: interactive authentication is required\r\n", "\r\n##rackoon-exit:1\r\n"]
        let run = await StreamRunner.run(transport: t, command: "x", cols: 80, rows: 24, sudo: credential, onEvent: { _ in })
        XCTAssertTrue(run.sudoAsksEveryTime)
        XCTAssertFalse(run.needsSudoPassword, "asking again would not help")
        XCTAssertEqual(run.sudoProblem, SudoElevation.asksEveryTime)
    }

    func testSudoNRefusalIsRecognisedEvenWhenThePipelineExitsZero() async {
        let t = FakeTransport([])
        t.streamChunks = ["sudo: interactive authentication is required\r\n", "\r\n##rackoon-exit:0\r\n"]
        let run = await StreamRunner.run(transport: t, command: "x", cols: 80, rows: 24, onEvent: { _ in })
        XCTAssertTrue(run.needsSudoPassword)
    }

    func testUpdatesAsksForAPasswordThenRunsThePasswordVariant() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: "##apt\nok\n##upgradable\nListing...\n##held\n##refreshed\n1\n##reboot\nno\n"))])
        t.streamChunks = ["sudo: interactive authentication is required\r\n", "\r\n##rackoon-exit:1\r\n"]
        let session = UpdatesSession(transport: t)
        await session.performStreaming(.refresh, confirmation: try session.confirm(.refresh), cols: 80, rows: 24, onEvent: { _ in })
        var state = await session.state
        XCTAssertTrue(state.sudoPasswordNeeded)
        // The plain confirmation does not authorise the password variant, nor does one for another nonce.
        await session.performStreaming(.refresh, confirmation: try session.confirm(.refresh), cols: 80, rows: 24, sudo: credential, onEvent: { _ in })
        state = await session.state
        XCTAssertEqual(state.actionError, PolicyError.notConfirmed.errorDescription)
        await session.performStreaming(.refresh, confirmation: try session.confirm(.refresh, sudoNonce: SudoElevation.makeNonce()),
                                       cols: 80, rows: 24, sudo: credential, onEvent: { _ in })
        state = await session.state
        XCTAssertEqual(state.actionError, PolicyError.notConfirmed.errorDescription)
        t.streamChunks = ["\(prompt)\r\n", "\(ok)\r\n", "Hit:1 http://archive.ubuntu.com\r\n", "\r\n##rackoon-exit:0\r\n"]
        await session.performStreaming(.refresh, confirmation: try session.confirm(.refresh, sudoNonce: nonce), cols: 80, rows: 24,
                                       sudo: credential, onEvent: { _ in })
        state = await session.state
        XCTAssertFalse(state.sudoPasswordNeeded)
        XCTAssertNil(state.actionError)
        XCTAssertTrue(t.streamedCommands.last?.contains("sudo -p '\(prompt)' -v") == true)
        let typed = await t.typedIntoStream()
        XCTAssertEqual(typed, ["hunter2\n"])
    }

    func testLibraryRootEntriesHaveAPasswordVariantAndOthersDoNot() throws {
        let session = CommandLibrarySession(transport: FakeTransport([]))
        let root = try XCTUnwrap(CommandLibrary.all.first { $0.id == "listening_ports" })
        let plain = try XCTUnwrap(CommandLibrary.all.first { $0.id == "disk_usage" })
        XCTAssertTrue(try XCTUnwrap(session.passwordIntent(for: root, nonce: nonce)).command.contains("sudo -p '\(prompt)' -v"))
        XCTAssertNil(session.passwordIntent(for: plain, nonce: nonce))
    }
}
