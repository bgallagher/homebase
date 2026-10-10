import Foundation
import XCTest
@testable import RackoonCore

final class ShellQuoteTests: XCTestCase {
    func testQuotesAsOneLiteralWord() {
        XCTAssertEqual(ShellQuote.quote("/srv/my app"), "'/srv/my app'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote("$(reboot);`id`"), "'$(reboot);`id`'")
    }

    func testRefusesValuesNoShellWordCanCarry() {
        for bad in ["", "a\nb", "a\rb", "a\0b"] { XCTAssertNil(ShellQuote.quote(bad), bad.debugDescription) }
        XCTAssertNil(ShellQuote.quotePath("relative/dir"))
        XCTAssertNotNil(ShellQuote.quotePath("/abs"))
    }

    /// Runs the quoted word through a real /bin/sh and checks it comes back unchanged.
    func testRealShellRoundTrip() throws {
        for value in ["/srv/my app", "/srv/it's here", "/srv/$(echo hacked)", "/srv/a;b|c&d", "/srv/`id`", "/srv/\"q\"", "/srv/back\\slash", "/srv/ünï"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf %s \(ShellQuote.quote(value)!)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), value)
        }
    }
}

final class ComposeActionTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: specDir.appendingPathComponent("fixtures/docker/\(name).out.txt"), encoding: .utf8)
    }

    private func stack(name: String = "media", dir: String? = "/srv/media", file: String? = "/srv/media/compose.yaml",
                       files: [String] = [], standalone: Bool = false) -> DockerStack {
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none",
                                status: "Up", ports: [], project: name, service: "web", workingDir: dir, configFile: file)
        return DockerStack(name: name, workingDir: dir, configFile: file, configFiles: files, containers: [c], isStandalone: standalone)
    }

    func testCommandsMatchSpecTemplates() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        for action in ComposeAction.allCases {
            let spec = commands.first { $0["id"] as? String == action.commandID }
            XCTAssertEqual(spec?["script"] as? String, action.template, action.rawValue)
            XCTAssertEqual(spec?["kind"] as? String, "action")
        }
        XCTAssertEqual(ComposeAction.pull.command(for: stack()),
                       "cd '/srv/media' && docker compose -p media -f '/srv/media/compose.yaml' pull")
        XCTAssertEqual(ComposeAction.rebuild.command(for: stack()),
                       "cd '/srv/media' && docker compose -p media -f '/srv/media/compose.yaml' up -d --build")
        XCTAssertEqual(ComposeAction.rebuild.timeout, 1800)
        XCTAssertEqual(ComposeAction.recreate.command(for: stack()),
                       "cd '/srv/media' && docker compose -p media -f '/srv/media/compose.yaml' up -d --force-recreate")
    }

    func testEveryComposeFileIsPassedInOrder() {
        let s = stack(files: ["/srv/media/compose.yaml", "/srv/media/compose.override.yaml"])
        XCTAssertEqual(ComposeAction.up.command(for: s),
                       "cd '/srv/media' && docker compose -p media -f '/srv/media/compose.yaml' -f '/srv/media/compose.override.yaml' up -d")
    }

    func testParserKeepsAllFilesAndAMangledListIsRefused() throws {
        func row(_ files: String) -> String {
            #"{"ID":"abcdef012345","Names":"a-web-1","Image":"i","State":"running","Status":"Up","Labels":"com.docker.compose.project=a,com.docker.compose.project.working_dir=/srv/a,com.docker.compose.project.config_files=\#(files),com.docker.compose.service=web"}"#
        }
        func stack(_ files: String) throws -> DockerStack {
            try XCTUnwrap(DockerParser.parse("##docker\nok\n##ps\n\(row(files))\n##stats\n").stacks.first)
        }
        let multi = try stack("/srv/a/compose.yml,/srv/a/compose.override.yml")
        XCTAssertEqual(multi.configFiles, ["/srv/a/compose.yml", "/srv/a/compose.override.yml"])
        XCTAssertEqual(multi.configFile, "/srv/a/compose.yml")
        XCTAssertNotNil(ComposeAction.up.command(for: multi))
        // A comma inside a path splits it into a piece that is not absolute: refuse rather than send a wrong -f.
        let mangled = try stack("/srv/a,b/compose.yml")
        XCTAssertEqual(mangled.configFiles, ["/srv/a", "b/compose.yml"])
        XCTAssertNil(ComposeAction.up.command(for: mangled))
    }

    func testContainersThatDisagreeOnTheComposeFilesGetNoCommand() throws {
        func row(_ id: String, _ files: String) -> String {
            #"{"ID":"\#(id)","Names":"n\#(id)","Image":"i","State":"running","Status":"Up","Labels":"com.docker.compose.project=a,com.docker.compose.project.working_dir=/srv/a,com.docker.compose.project.config_files=\#(files),com.docker.compose.service=s\#(id)"}"#
        }
        let out = "##docker\nok\n##ps\n\(row("abcdef012345", "/srv/a/compose.yml"))\n\(row("abcdef012346", "/srv/a/old.yml"))\n##stats\n"
        let s = try XCTUnwrap(DockerParser.parse(out).stacks.first)
        XCTAssertNil(s.workingDir)
        XCTAssertNil(ComposeAction.up.command(for: s))
    }

    func testUnsafeOrMissingStackDataIsRefused() {
        for action in ComposeAction.allCases {
            XCTAssertNil(action.command(for: stack(name: "media; reboot")))
            XCTAssertNil(action.command(for: stack(name: "Media")))
            XCTAssertNil(action.command(for: stack(name: "-x")))
            XCTAssertNil(action.command(for: stack(dir: nil)))
            XCTAssertNil(action.command(for: stack(file: nil)))
            XCTAssertNil(action.command(for: stack(dir: "relative")))
            XCTAssertNil(action.command(for: stack(standalone: true)))
        }
    }

    func testQuotesPathsWithSpacesAndQuotes() {
        let c = ComposeAction.up.command(for: stack(dir: "/srv/it's mine", file: "/srv/it's mine/docker-compose.yml"))
        XCTAssertEqual(c, "cd '/srv/it'\\''s mine' && docker compose -p media -f '/srv/it'\\''s mine/docker-compose.yml' up -d")
    }

    func testPerformNeedsConfirmationAndHonoursReadOnly() async throws {
        let s = stack()
        let transport = FakeTransport([])
        let session = DockerSession(transport: transport)
        await session.perform(.pull, stack: s, confirmation: nil)
        XCTAssertTrue(transport.commands.isEmpty)
        var error = await session.state.actionError
        XCTAssertEqual(error, PolicyError.notConfirmed.errorDescription)

        // A confirmation for pull cannot run recreate.
        let pullOK = try session.confirm(.pull, stack: s)
        await session.perform(.recreate, stack: s, confirmation: pullOK)
        XCTAssertTrue(transport.commands.isEmpty)

        let readOnly = DockerSession(transport: transport, policy: ActionPolicy(readOnly: true))
        XCTAssertThrowsError(try readOnly.confirm(.up, stack: s))
        await readOnly.perform(.up, stack: s, confirmation: nil)
        XCTAssertTrue(transport.commands.isEmpty)
        error = await readOnly.state.actionError
        XCTAssertEqual(error, PolicyError.readOnly.errorDescription)
    }

    func testPerformRunsMarksBusyThenRefreshes() async throws {
        let s = stack()
        let transport = FakeTransport([
            .success(CommandResult(stdout: "", stderr: "Pulling\n", exitCode: 0)),
            .success(CommandResult(stdout: try fixture("ubuntu-24.04-compose"))),
        ])
        let session = DockerSession(transport: transport)
        await session.perform(.pull, stack: s, confirmation: try session.confirm(.pull, stack: s))
        XCTAssertEqual(transport.commands.first, ComposeAction.pull.command(for: s))
        XCTAssertEqual(transport.commands.count, 2, "runs, then refreshes")
        let state = await session.state
        XCTAssertTrue(state.busy.isEmpty)
        XCTAssertTrue(state.busyStacks.isEmpty, "cleared when the action finishes")
        XCTAssertNil(state.actionError)
    }

    /// While the command runs, the stack is busy by name, even for containers that did not exist when it started.
    func testStackIsBusyByNameWhileTheCommandRuns() async throws {
        final class Gate: SSHTransport, @unchecked Sendable {
            let started = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            var count = 0
            let snapshot: String
            init(snapshot: String) { self.snapshot = snapshot }
            func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
                count += 1
                if count == 1 {
                    started.continuation.yield()
                    for await _ in release.stream { break }
                    return CommandResult(stdout: "")
                }
                return CommandResult(stdout: snapshot)
            }
            func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        }
        let s = stack()
        let gate = Gate(snapshot: try fixture("ubuntu-24.04-compose"))
        let session = DockerSession(transport: gate)
        let confirmation = try session.confirm(.up, stack: s)
        let task = Task { await session.perform(.up, stack: s, confirmation: confirmation) }
        for await _ in gate.started.stream { break }
        let during = await session.state
        XCTAssertEqual(during.busyStacks, ["media"])
        gate.release.continuation.yield()
        await task.value
        let after = await session.state
        XCTAssertTrue(after.busyStacks.isEmpty)
    }

    func testFailureReportsTheLastLinesOfStderr() async throws {
        let s = stack()
        let stderr = "line1\nline2\nline3\nError response from daemon: pull access denied"
        let transport = FakeTransport([
            .success(CommandResult(stdout: "", stderr: stderr, exitCode: 1)),
            .success(CommandResult(stdout: try fixture("ubuntu-24.04-compose"))),
        ])
        let session = DockerSession(transport: transport)
        await session.perform(.up, stack: s, confirmation: try session.confirm(.up, stack: s))
        let error = await session.state.actionError
        XCTAssertEqual(error, "line2\nline3\nError response from daemon: pull access denied")
    }
}
