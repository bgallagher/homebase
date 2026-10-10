import Foundation
import XCTest
@testable import RackoonCore

final class StackFileParserTests: XCTestCase {
    /// Every fixture in spec/fixtures/file_read must parse to its expected JSON (shared with the Kotlin core).
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/file_read")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") }.sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(outs.count, 7)
        for out in outs {
            let expectedURL = URL(fileURLWithPath: out.path.replacingOccurrences(of: ".out.txt", with: ".expected.json"))
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? NSDictionary
            XCTAssertEqual(parsed(try String(contentsOf: out, encoding: .utf8)), expected, out.lastPathComponent)
        }
    }

    private func parsed(_ text: String) -> NSDictionary {
        do {
            switch try RemoteFileParser.parse(text) {
            case .missing: return ["state": "missing"]
            case .tooLarge: return ["state": "tooLarge"]
            case .file(let f):
                return ["state": "file", "content": f.content, "sha256": f.sha256, "mode": f.mode, "owner": f.owner, "modifiedAt": f.modifiedAt]
            }
        } catch StackFileError.notText {
            return ["error": "notText"]
        } catch {
            return ["error": "other", "message": "\(error)"]
        }
    }

    func testCRLFAndMissingTrailingNewlineSurviveExactly() throws {
        let crlf = try RemoteFileParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/file_read/unicode-and-crlf.out.txt"), encoding: .utf8))
        XCTAssertTrue(crlf.content?.contains("\r\n") == true)
        let env = try RemoteFileParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/file_read/env-no-trailing-newline.out.txt"), encoding: .utf8))
        XCTAssertEqual(env.content?.hasSuffix("info"), true, "no newline was added")
    }

    func testBrokenOutputIsMalformedNotEmpty() {
        XCTAssertThrowsError(try RemoteFileParser.parse("")) { XCTAssertEqual($0 as? StackFileError, .malformed("no ##meta")) }
        XCTAssertThrowsError(try RemoteFileParser.parse("##meta\n1 644 root:root\n##sha256\nabc\n##content\nAAAA\n"))
        XCTAssertThrowsError(try RemoteFileParser.parse("##meta\n1 644 root:root\n##sha256\n\(String(repeating: "a", count: 64))\n##content\n!!!notbase64\n"))
    }
}

final class ComposeIssueParserTests: XCTestCase {
    func testYAMLSyntaxErrorHasItsLine() {
        let issues = ComposeIssueParser.parse("yaml: line 5: could not find expected ':'\n")
        XCTAssertEqual(issues, [ComposeIssue(severity: .error, line: 5, message: "could not find expected ':'")])
    }

    func testIndentedUnmarshalLinesAndSchemaErrors() {
        let issues = ComposeIssueParser.parse("""
        yaml: unmarshal errors:
          line 3: field imagee not found in type types.ServiceConfig
        validating /srv/a/compose.yaml: services.web Additional property foo is not allowed
        """)
        XCTAssertEqual(issues.map(\.line), [nil, 3, nil])
        XCTAssertTrue(issues.allSatisfy { $0.severity == .error })
        XCTAssertEqual(issues[1].message, "field imagee not found in type types.ServiceConfig")
    }

    func testNewerComposeErrorFormatHasItsLineAndTheTempNameIsReplaced() {
        let out = "failed to parse /srv/a/.rackoon-check.AfWne0: go-yaml load error in scanner at L4.C12: mapping values are not allowed in this context\n"
        let raw = ComposeIssueParser.parse(out)
        XCTAssertEqual(raw.first?.line, 4)
        XCTAssertEqual(raw.first?.message, "mapping values are not allowed in this context")
        let schema = ComposeIssueParser.parse("validating /srv/a/.rackoon-save.y1DKDz: services.web.imagee false schema\n")[0]
        XCTAssertEqual(schema.naming(.compose("/srv/a/compose.yaml")).message, "validating compose.yaml: services.web.imagee false schema")
        let parse = ComposeIssueParser.parse("failed to parse /srv/a/.rackoon-save.y1DKDz: bad\n")[0]
        XCTAssertEqual(parse.naming(.env("/srv/a/.env")).message, "failed to parse .env: bad")
    }

    func testWarningsAreNotErrors() {
        let issues = ComposeIssueParser.parse(#"time="2026-10-10T03:08:33Z" level=warning msg="/opt/stacks/monitoring/compose.yaml: the attribute `version` is obsolete, it will be ignored""# + "\n")
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertTrue(issues[0].message.hasSuffix("it will be ignored"))
        XCTAssertTrue(ValidationResult(issues: issues).isValid)
    }

    func testMarkersAndBlankLinesAreIgnored() {
        XCTAssertEqual(ComposeIssueParser.parse("##invalid\n\n   \n"), [])
    }
}

final class LineDiffTests: XCTestCase {
    func testChangedAddedRemovedAndSame() {
        let old = "a\nb\nc\n"
        let new = "a\nB\nc\nd\n"
        XCTAssertEqual(LineDiff.changedLineNumbers(old: old, new: new), [2, 4])
        XCTAssertEqual(LineDiff.changeCount(old: old, new: new), 3, "b removed, B added, d added")
        XCTAssertEqual(LineDiff.changeCount(old: old, new: old), 0)
        XCTAssertEqual(LineDiff.lines(old: "", new: "x\n").map(\.kind), [.added])
        XCTAssertEqual(LineDiff.lines(old: "x\n", new: "").map(\.kind), [.removed])
    }

    func testTrailingNewlineIsNotAChange() {
        XCTAssertEqual(LineDiff.changeCount(old: "a\nb", new: "a\nb\n"), 0)
    }

    func testPreviewShowsOnlyChangesWithContext() {
        let old = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line10\n", with: "changed\n")
        let preview = LineDiff.preview(old: old, new: new)
        XCTAssertTrue(preview.contains("- line10"))
        XCTAssertTrue(preview.contains("+ changed"))
        XCTAssertTrue(preview.contains("  line8"))
        XCTAssertFalse(preview.contains("line1\n"), "far-away lines are left out")
        XCTAssertEqual(LineDiff.preview(old: old, new: old), "No changes.")
    }
}

final class StackFileCommandTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)

    private func stack(files: [String] = ["/srv/media/compose.yaml"], dir: String = "/srv/media") -> DockerStack {
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none",
                                status: "Up", ports: [], project: "media", service: "web", workingDir: dir,
                                configFile: files.first, configFiles: files)
        return DockerStack(name: "media", workingDir: dir, configFile: files.first, configFiles: files, containers: [c], isStandalone: false)
    }

    func testTemplatesMatchSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func script(_ id: String) -> String? { commands.first { $0["id"] as? String == id }?["script"] as? String }
        XCTAssertEqual(StackFileCommands.readTemplate, script("file_read"))
        XCTAssertEqual(StackFileCommands.validateTemplate, script("file_validate"))
        XCTAssertEqual(StackFileCommands.writeTemplate, script("file_write"))
    }

    func testEditableFilesAreComposeFilesThenEnv() {
        let s = stack(files: ["/srv/media/compose.yaml", "/srv/media/compose.override.yaml"])
        XCTAssertEqual(StackFiles.editable(for: s), [.compose("/srv/media/compose.yaml"), .compose("/srv/media/compose.override.yaml"), .env("/srv/media/.env")])
        XCTAssertEqual(StackFiles.editable(for: stack(dir: "/srv/media/")), [.compose("/srv/media/compose.yaml"), .env("/srv/media/.env")])
        var standalone = stack(); standalone.isStandalone = true
        XCTAssertNil(StackFiles.editable(for: standalone))
    }

    func testOnlyTheStacksOwnFilesCanBeTouched() {
        let s = stack()
        for evil in [EditableFile.compose("/etc/passwd"), .env("/etc/shadow"), .compose("/srv/media/../../etc/passwd"), .env("/srv/media/other.env")] {
            XCTAssertNil(StackFileCommands.read(evil, in: s), evil.path)
            XCTAssertNil(StackFileCommands.validate(evil, content: "x", in: s), evil.path)
            XCTAssertNil(StackFileCommands.write(evil, content: "x", expectedSHA: nil, in: s), evil.path)
        }
        XCTAssertNotNil(StackFileCommands.read(.compose("/srv/media/compose.yaml"), in: s))
        XCTAssertNotNil(StackFileCommands.read(.env("/srv/media/.env"), in: s))
    }

    func testValidateSwapsTheEditedComposeFileForTheTempFile() throws {
        let s = stack(files: ["/srv/media/compose.yaml", "/srv/media/compose.override.yaml"])
        let c = try XCTUnwrap(StackFileCommands.validate(.compose("/srv/media/compose.override.yaml"), content: "services: {}\n", in: s))
        XCTAssertTrue(c.contains(#"-f '/srv/media/compose.yaml' -f "$T" config -q"#), c)
        XCTAssertFalse(c.contains("--env-file"))
        let env = try XCTUnwrap(StackFileCommands.validate(.env("/srv/media/.env"), content: "A=1\n", in: s))
        XCTAssertTrue(env.contains(#"--env-file "$T" -f '/srv/media/compose.yaml' -f '/srv/media/compose.override.yaml' config -q"#), env)
    }

    func testContentTravelsAsQuotedBase64AndRoundTrips() throws {
        let content = "services:\n  web:\n    image: \"it's $(whoami) `id`; rm -rf /\"\n"
        let c = try XCTUnwrap(StackFileCommands.validate(.compose("/srv/media/compose.yaml"), content: content, in: stack()))
        XCTAssertFalse(c.contains("whoami"), "content must never appear in the command as text")
        let b64 = try XCTUnwrap(c.range(of: #"echo '([A-Za-z0-9+/=]*)' \| base64"#, options: .regularExpression))
        let encoded = c[b64].dropFirst(6).prefix { $0 != "'" }
        XCTAssertEqual(String(data: Data(base64Encoded: String(encoded))!, encoding: .utf8), content)
    }

    func testWriteGuardsAgainstChangesAndNewFiles() throws {
        let existing = try XCTUnwrap(StackFileCommands.write(.compose("/srv/media/compose.yaml"), content: "x\n", expectedSHA: sha, in: stack()))
        XCTAssertTrue(existing.contains("= '\(sha)' ] || { echo '##changed'; exit 3; }"))
        XCTAssertTrue(existing.contains("cp -p \"$F\" \"$F.rackoon.bak\""))
        XCTAssertTrue(existing.contains("mv -f \"$T\" \"$F\""))
        // validation comes before the backup and the move
        let v = try XCTUnwrap(existing.range(of: "config -q")), m = try XCTUnwrap(existing.range(of: "mv -f"))
        XCTAssertLessThan(v.lowerBound, m.lowerBound)
        let new = try XCTUnwrap(StackFileCommands.write(.env("/srv/media/.env"), content: "A=1\n", expectedSHA: nil, in: stack()))
        XCTAssertTrue(new.contains(#"[ ! -e "$F" ] || { echo '##changed'; exit 3; }"#))
        for bad in ["", "abc", String(repeating: "A", count: 64), String(repeating: "a", count: 63) + "'"] {
            XCTAssertNil(StackFileCommands.write(.compose("/srv/media/compose.yaml"), content: "x", expectedSHA: bad, in: stack()), bad)
        }
    }

    func testAnEmptyFileCanBeValidatedAndSaved() throws {
        let c = try XCTUnwrap(StackFileCommands.validate(.env("/srv/media/.env"), content: "", in: stack()))
        XCTAssertTrue(c.contains("echo '' | base64 -d"), c)
        XCTAssertNotNil(StackFileCommands.write(.env("/srv/media/.env"), content: "", expectedSHA: sha, in: stack()))
    }

    func testSizeCapAndPlaceholderLookalikesInPaths() throws {
        XCTAssertNotNil(StackFileCommands.validate(.compose("/srv/media/compose.yaml"), content: String(repeating: "a", count: StackFiles.maxBytes), in: stack()))
        XCTAssertNil(StackFileCommands.validate(.compose("/srv/media/compose.yaml"), content: String(repeating: "a", count: StackFiles.maxBytes + 1), in: stack()))
        // A path containing placeholder text is inserted literally, never substituted again.
        let tricky = stack(files: ["/srv/{b64}/compose.yaml"], dir: "/srv/{b64}")
        let c = try XCTUnwrap(StackFileCommands.read(.compose("/srv/{b64}/compose.yaml"), in: tricky))
        XCTAssertTrue(c.hasPrefix("F='/srv/{b64}/compose.yaml';"), c)
    }
}

final class StackFileSessionTests: XCTestCase {
    private let sha = String(repeating: "b", count: 64)
    private let file = EditableFile.compose("/srv/media/compose.yaml")

    private func stack() -> DockerStack {
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none",
                                status: "Up", ports: [], project: "media", service: "web", workingDir: "/srv/media",
                                configFile: "/srv/media/compose.yaml", configFiles: ["/srv/media/compose.yaml"])
        return DockerStack(name: "media", workingDir: "/srv/media", configFile: "/srv/media/compose.yaml",
                           configFiles: ["/srv/media/compose.yaml"], containers: [c], isStandalone: false)
    }

    private func edit(_ content: String = "services:\n  web:\n    image: nginx:1\n") -> FileEdit {
        FileEdit(file: file, original: "services:\n  web:\n    image: nginx\n", originalSHA: sha, content: content)
    }

    func testReadParsesAndRefusesForeignFiles() async throws {
        let out = try String(contentsOf: specDir.appendingPathComponent("fixtures/file_read/compose-normal.out.txt"), encoding: .utf8)
        let t = FakeTransport([.success(CommandResult(stdout: out))])
        let session = StackFileSession(transport: t, stack: stack())
        let state = try await session.read(file)
        XCTAssertTrue(state.content?.hasPrefix("services:") == true)
        do { _ = try await session.read(.compose("/etc/passwd")); XCTFail("should refuse") }
        catch { XCTAssertEqual(error as? StackFileError, .notEditable("/etc/passwd")) }
        XCTAssertEqual(t.commands.count, 1, "the foreign read never reached the server")
    }

    func testValidateMapsOutputToIssuesAndNeverReadsFailureAsValid() async throws {
        let bad = FakeTransport([.success(CommandResult(stdout: "yaml: line 5: could not find expected ':'\n", exitCode: 1))])
        var result = try await StackFileSession(transport: bad, stack: stack()).validate(file, content: "x")
        XCTAssertEqual(result.errors.first?.line, 5)
        XCTAssertFalse(result.isValid)

        let warn = FakeTransport([.success(CommandResult(stdout: #"time="t" level=warning msg="version is obsolete""# + "\n"))])
        result = try await StackFileSession(transport: warn, stack: stack()).validate(file, content: "x")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.warnings.count, 1)

        let opaque = FakeTransport([.success(CommandResult(stdout: "", stderr: "docker: command not found", exitCode: 127))])
        result = try await StackFileSession(transport: opaque, stack: stack()).validate(file, content: "x")
        XCTAssertFalse(result.isValid, "a failure with no parseable error is still a failure")
        XCTAssertTrue(result.errors.first?.message.contains("command not found") == true)

        let readonly = FakeTransport([.success(CommandResult(stdout: "##cannot-write\n", exitCode: 7))])
        do { _ = try await StackFileSession(transport: readonly, stack: stack()).validate(file, content: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? StackFileError, .cannotWrite) }
    }

    func testSaveNeedsConfirmationAndHonoursReadOnly() async throws {
        let t = FakeTransport([])
        let session = StackFileSession(transport: t, stack: stack())
        do { _ = try await session.save(edit(), confirmation: nil); XCTFail() }
        catch { XCTAssertEqual(error as? PolicyError, .notConfirmed) }
        // A confirmation for one edit cannot save a different one.
        let confirmed = try session.confirm(edit("a: 1\n"))
        do { _ = try await session.save(edit("b: 2\n"), confirmation: confirmed); XCTFail() }
        catch { XCTAssertEqual(error as? PolicyError, .notConfirmed) }

        let ro = StackFileSession(transport: t, policy: ActionPolicy(readOnly: true), stack: stack())
        XCTAssertThrowsError(try ro.confirm(edit())) { XCTAssertEqual($0 as? PolicyError, .readOnly) }
        XCTAssertTrue(t.commands.isEmpty)
    }

    func testIntentPreviewIsTheDiffNotTheCommand() throws {
        let intent = try XCTUnwrap(StackFileSession(transport: FakeTransport([]), stack: stack()).intent(for: edit()))
        XCTAssertEqual(intent.risk, .mutate)
        XCTAssertTrue(intent.preview?.contains("+     image: nginx:1") == true, intent.preview ?? "nil")
        XCTAssertTrue(intent.preview?.contains("-     image: nginx") == true)
        XCTAssertEqual(edit().changeCount, 2)
    }

    func testSaveOutcomes() async throws {
        let newSHA = String(repeating: "c", count: 64)
        func outcome(_ r: CommandResult) async throws -> SaveOutcome {
            let session = StackFileSession(transport: FakeTransport([.success(r)]), stack: stack())
            return try await session.save(edit(), confirmation: try session.confirm(edit()))
        }
        let saved = try await outcome(CommandResult(stdout: "##saved\n\(newSHA)\n"))
        XCTAssertEqual(saved, .saved(sha256: newSHA))
        let changed = try await outcome(CommandResult(stdout: "##changed\n", exitCode: 3))
        XCTAssertEqual(changed, .changedOnServer)
        let invalid = try await outcome(CommandResult(stdout: "##invalid\nyaml: line 3: mapping values are not allowed here\n", exitCode: 4))
        XCTAssertEqual(invalid, .invalid([ComposeIssue(severity: .error, line: 3, message: "mapping values are not allowed here")]))
        do { _ = try await outcome(CommandResult(stdout: "##cannot-write\n", exitCode: 7)); XCTFail() }
        catch { XCTAssertEqual(error as? StackFileError, .cannotWrite) }
        do { _ = try await outcome(CommandResult(stdout: "", exitCode: 0)); XCTFail("success without ##saved must not count") }
        catch { XCTAssertEqual(error as? StackFileError, .malformed("save did not confirm")) }
    }

    func testTooLargeContentIsRefusedBeforeAnythingIsSent() async throws {
        let t = FakeTransport([])
        let session = StackFileSession(transport: t, stack: stack())
        let big = edit(String(repeating: "a", count: StackFiles.maxBytes + 1))
        do { _ = try await session.save(big, confirmation: nil); XCTFail() }
        catch { XCTAssertEqual(error as? StackFileError, .tooLarge) }
        do { _ = try await session.validate(file, content: big.content); XCTFail() }
        catch { XCTAssertEqual(error as? StackFileError, .tooLarge) }
        XCTAssertTrue(t.commands.isEmpty)
    }
}
