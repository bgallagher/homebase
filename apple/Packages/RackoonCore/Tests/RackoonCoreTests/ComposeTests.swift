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
                       standalone: Bool = false) -> DockerStack {
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none",
                                status: "Up", ports: [], project: name, service: "web", workingDir: dir, configFile: file)
        return DockerStack(name: name, workingDir: dir, configFile: file, containers: [c], isStandalone: standalone)
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
        XCTAssertEqual(ComposeAction.recreate.command(for: stack()),
                       "cd '/srv/media' && docker compose -p media -f '/srv/media/compose.yaml' up -d --force-recreate")
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
        XCTAssertNil(state.actionError)
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
