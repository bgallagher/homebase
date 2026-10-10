import Foundation
import XCTest
@testable import RackoonCore

final class SyntaxHighlighterTests: XCTestCase {
    /// (text, kind) pairs for a whole document, in order.
    private func spans(_ text: String, env: Bool = false) -> [(String, SyntaxKind)] {
        let ns = text as NSString
        return (env ? SyntaxHighlighter.env(text) : SyntaxHighlighter.yaml(text)).map {
            (ns.substring(with: NSRange(location: $0.location, length: $0.length)), $0.kind)
        }
    }

    func testKeysValuesAndPunctuation() {
        let r = spans("services:\n  web:\n    image: nginx:alpine\n    restart: unless-stopped\n")
        XCTAssertEqual(r.map(\.0), ["services", ":", "web", ":", "image", ":", "restart", ":"])
        XCTAssertEqual(r.filter { $0.1 == .key }.map(\.0), ["services", "web", "image", "restart"])
    }

    func testListItemsStringsNumbersKeywordsAndComments() {
        let r = spans("    ports:\n      - \"8085:80\"\n      - 3000:3000\n    tty: true # keep open\n    # whole line\n")
        XCTAssertTrue(r.contains { $0 == ("\"8085:80\"", .string) })
        XCTAssertTrue(r.contains { $0 == ("3000:3000", .number) })
        XCTAssertTrue(r.contains { $0 == ("true", .keyword) })
        XCTAssertTrue(r.contains { $0 == ("# keep open", .comment) })
        XCTAssertTrue(r.contains { $0 == ("# whole line", .comment) })
        XCTAssertEqual(r.filter { $0.1 == .punctuation && $0.0 == "-" }.count, 2)
    }

    func testColonsInsideValuesAndQuotesAreNotKeys() {
        let r = spans("    image: ghcr.io/foo/bar:latest\n    command: \"a: b\"\n    url: http://x:80/y\n")
        XCTAssertEqual(r.filter { $0.1 == .key }.map(\.0), ["image", "command", "url"])
        XCTAssertTrue(r.contains { $0 == ("\"a: b\"", .string) })
    }

    func testInterpolationAndHashInsideAWord() {
        let r = spans("    image: busybox:${TAG:?needed}\n    note: a#b\n")
        XCTAssertTrue(r.contains { $0 == ("busybox:${TAG:?needed}", .keyword) } == false, "only a leading $ is a variable")
        XCTAssertFalse(r.contains { $0.1 == .comment }, "a # glued to a word is not a comment")
        XCTAssertTrue(spans("    p: ${PORT}\n").contains { $0 == ("${PORT}", .keyword) })
    }

    func testOffsetsAreUTF16AndSurviveCRLFAndEmoji() {
        let text = "a: \"café ☕\"\r\nb: 1\r\n"
        let ns = text as NSString
        for t in SyntaxHighlighter.yaml(text) { XCTAssertLessThanOrEqual(t.location + t.length, ns.length) }
        let r = spans(text)
        XCTAssertTrue(r.contains { $0 == ("\"café ☕\"", .string) })
        XCTAssertTrue(r.contains { $0 == ("1", .number) })
        XCTAssertFalse(r.contains { $0.0.contains("\r") })
    }

    func testEnvFiles() {
        let r = spans("# comment\nTZ=Europe/Dublin\nexport NAME=\"quoted # not comment\"  # real\nEMPTY=\nLOG=info # trailing\n", env: true)
        XCTAssertEqual(r.filter { $0.1 == .key }.map(\.0), ["TZ", "NAME", "EMPTY", "LOG"])
        XCTAssertTrue(r.contains { $0 == ("Europe/Dublin", .string) })
        XCTAssertTrue(r.contains { $0 == ("\"quoted # not comment\"", .string) })
        XCTAssertTrue(r.contains { $0 == ("# real", .comment) })
        XCTAssertTrue(r.contains { $0 == ("info", .string) })
        XCTAssertTrue(r.contains { $0 == ("# trailing", .comment) })
    }

    func testNeverCrashesOnOddInput() {
        for text in ["", "\n\n", ":", "- ", "\"", "a:", "x: \"unterminated", "\u{0}", String(repeating: "- ", count: 500), "=", "export "] {
            _ = SyntaxHighlighter.yaml(text)
            _ = SyntaxHighlighter.env(text)
        }
    }
}

final class EnvSyntaxTests: XCTestCase {
    func testAcceptsNormalFiles() {
        XCTAssertEqual(EnvSyntax.check("# c\n\nTZ=Europe/Dublin\nexport A_B=1\nA.B-C=x\nEMPTY=\n"), [])
        XCTAssertEqual(EnvSyntax.check(""), [])
    }

    func testReportsTheLineAndReason() {
        let issues = EnvSyntax.check("OK=1\nLOG LEVEL=info\nnoequals\n=value\n9BAD=x\n")
        XCTAssertEqual(issues.map(\.line), [2, 3, 4, 5])
        XCTAssertEqual(issues[0].message, "Variable names cannot contain spaces")
        XCTAssertEqual(issues[1].message, "Expected NAME=value")
        XCTAssertEqual(issues[2].message, "Missing variable name before =")
        XCTAssertTrue(issues[3].message.hasPrefix("Invalid variable name"))
        XCTAssertTrue(issues.allSatisfy { $0.severity == .error })
    }
}

final class EditorChecksTests: XCTestCase {
    private func rows(isEnv: Bool = false, local: [ComposeIssue] = [], checkError: String? = nil,
                      issues: [ComposeIssue]? = nil, validatedText: String? = "t", text: String = "t") -> [EditorCheckRow] {
        EditorChecks.rows(isEnv: isEnv, serverName: "hetzner", local: local, checkError: checkError,
                          validation: issues.map { ValidationResult(issues: $0) }, validatedText: validatedText, text: text)
    }
    private func err(_ message: String, line: Int? = nil) -> ComposeIssue { ComposeIssue(severity: .error, line: line, message: message) }
    private func states(_ r: [EditorCheckRow]) -> [EditorCheckRow.State] { r.map(\.state) }

    func testAllPassForAValidFile() {
        let r = rows(issues: [])
        XCTAssertEqual(r.map(\.id), ["syntax", "schema", "config"])
        XCTAssertEqual(states(r), [.pass, .pass, .pass])
        XCTAssertTrue(r[2].detail.contains("hetzner"))
    }

    func testSyntaxErrorSkipsTheRestAndShowsTheLine() {
        let r = rows(issues: [err("mapping values are not allowed here", line: 4)])
        XCTAssertEqual(states(r), [.fail, .skipped, .skipped])
        XCTAssertEqual(r[0].detail, "Line 4: mapping values are not allowed here")
    }

    func testSchemaErrorFailsSchemaAndSkipsConfig() {
        let r = rows(issues: [err("validating compose.yaml: services.web.imagee false schema")])
        XCTAssertEqual(states(r), [.pass, .fail, .skipped])
    }

    func testInterpolationErrorFailsOnlyTheConfigCheck() {
        let r = rows(issues: [err("error while interpolating services.web.image: required variable TAG is missing a value")])
        XCTAssertEqual(states(r), [.pass, .pass, .fail])
    }

    func testWarningsAreListedAndDoNotFail() {
        let r = rows(issues: [ComposeIssue(severity: .warning, line: nil, message: "version is obsolete")])
        XCTAssertEqual(states(r), [.pass, .pass, .pass, .warn])
        XCTAssertEqual(r.last?.detail, "version is obsolete")
    }

    func testAResultForOlderTextIsNeverShownAsCurrent() {
        XCTAssertEqual(states(rows(issues: [], validatedText: "old", text: "new")), [.running])
        XCTAssertEqual(states(rows(issues: nil, validatedText: nil)), [.running])
    }

    func testCheckThatCouldNotRunIsAFailureNotASilentPass() {
        let r = rows(checkError: "Rackoon can't write in the stack's folder")
        XCTAssertEqual(states(r), [.fail])
        XCTAssertTrue(r[0].title.contains("hetzner"))
    }

    func testEnvFilesCheckLocalSyntaxThenTheComposeCheck() {
        let bad = rows(isEnv: true, local: [err("Variable names cannot contain spaces", line: 3)], issues: nil)
        XCTAssertEqual(bad.map(\.id), ["syntax", "config"])
        XCTAssertEqual(states(bad), [.fail, .skipped])
        XCTAssertEqual(bad[0].detail, "Line 3: Variable names cannot contain spaces")
        XCTAssertEqual(states(rows(isEnv: true, issues: [])), [.pass, .pass])
        let missing = rows(isEnv: true, issues: [err("required variable TAG is missing a value: TAG is required")])
        XCTAssertEqual(states(missing), [.pass, .fail])
    }
}
