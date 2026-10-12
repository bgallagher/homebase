package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SyntaxHighlighterTests {
    /** (text, kind) pairs for a whole document, in order. */
    private fun spans(text: String, env: Boolean = false): List<Pair<String, SyntaxKind>> =
        (if (env) SyntaxHighlighter.env(text) else SyntaxHighlighter.yaml(text)).map { text.substring(it.start, it.start + it.length) to it.kind }

    @Test fun `keys values and punctuation`() {
        val r = spans("services:\n  web:\n    image: nginx:alpine\n    restart: unless-stopped\n")
        assertEquals(listOf("services", ":", "web", ":", "image", ":", "restart", ":"), r.map { it.first })
        assertEquals(listOf("services", "web", "image", "restart"), r.filter { it.second == SyntaxKind.KEY }.map { it.first })
    }

    @Test fun `list items strings numbers keywords and comments`() {
        val r = spans("    ports:\n      - \"8085:80\"\n      - 3000:3000\n    tty: true # keep open\n    # whole line\n")
        assertTrue(("\"8085:80\"" to SyntaxKind.STRING) in r)
        assertTrue(("3000:3000" to SyntaxKind.NUMBER) in r)
        assertTrue(("true" to SyntaxKind.KEYWORD) in r)
        assertTrue(("# keep open" to SyntaxKind.COMMENT) in r)
        assertTrue(("# whole line" to SyntaxKind.COMMENT) in r)
        assertEquals(2, r.count { it.second == SyntaxKind.PUNCTUATION && it.first == "-" })
    }

    @Test fun `colons inside values and quotes are not keys`() {
        val r = spans("    image: ghcr.io/foo/bar:latest\n    command: \"a: b\"\n    url: http://x:80/y\n")
        assertEquals(listOf("image", "command", "url"), r.filter { it.second == SyntaxKind.KEY }.map { it.first })
        assertTrue(("\"a: b\"" to SyntaxKind.STRING) in r)
    }

    @Test fun `interpolation and a hash inside a word`() {
        val r = spans("    image: busybox:\${TAG:?needed}\n    note: a#b\n")
        assertFalse(("busybox:\${TAG:?needed}" to SyntaxKind.KEYWORD) in r, "only a leading \$ is a variable")
        assertFalse(r.any { it.second == SyntaxKind.COMMENT }, "a # glued to a word is not a comment")
        assertTrue(("\${PORT}" to SyntaxKind.KEYWORD) in spans("    p: \${PORT}\n"))
    }

    @Test fun `offsets are UTF-16 and survive CRLF and emoji`() {
        val text = "a: \"café ☕\"\r\nb: 1\r\n"
        for (t in SyntaxHighlighter.yaml(text)) assertTrue(t.start + t.length <= text.length)
        val r = spans(text)
        assertTrue(("\"café ☕\"" to SyntaxKind.STRING) in r)
        assertTrue(("1" to SyntaxKind.NUMBER) in r)
        assertFalse(r.any { it.first.contains("\r") })
    }

    @Test fun `env files`() {
        val r = spans("# comment\nTZ=Europe/Dublin\nexport NAME=\"quoted # not comment\"  # real\nEMPTY=\nLOG=info # trailing\n", env = true)
        assertEquals(listOf("TZ", "NAME", "EMPTY", "LOG"), r.filter { it.second == SyntaxKind.KEY }.map { it.first })
        assertTrue(("Europe/Dublin" to SyntaxKind.STRING) in r)
        assertTrue(("\"quoted # not comment\"" to SyntaxKind.STRING) in r)
        assertTrue(("# real" to SyntaxKind.COMMENT) in r)
        assertTrue(("info" to SyntaxKind.STRING) in r)
        assertTrue(("# trailing" to SyntaxKind.COMMENT) in r)
    }

    @Test fun `never crashes on odd input`() {
        for (text in listOf("", "\n\n", ":", "- ", "\"", "a:", "x: \"unterminated", "\u0000", "- ".repeat(500), "=", "export ")) {
            SyntaxHighlighter.yaml(text)
            SyntaxHighlighter.env(text)
        }
    }
}

class EnvSyntaxTests {
    @Test fun `accepts normal files`() {
        assertEquals(emptyList(), EnvSyntax.check("# c\n\nTZ=Europe/Dublin\nexport A_B=1\nA.B-C=x\nEMPTY=\n"))
        assertEquals(emptyList(), EnvSyntax.check(""))
    }

    @Test fun `reports the line and reason`() {
        val issues = EnvSyntax.check("OK=1\nLOG LEVEL=info\nnoequals\n=value\n9BAD=x\n")
        assertEquals(listOf(2, 3, 4, 5), issues.map { it.line })
        assertEquals("Variable names cannot contain spaces", issues[0].message)
        assertEquals("Expected NAME=value", issues[1].message)
        assertEquals("Missing variable name before =", issues[2].message)
        assertTrue(issues[3].message.startsWith("Invalid variable name"))
        assertTrue(issues.all { it.severity == ComposeIssue.Severity.ERROR })
    }

    @Test fun `names lists the defined variables`() {
        assertEquals(listOf("A", "B"), EnvSyntax.names("# c\nA=1\nexport B=2\nnoequals\n=x\n"))
    }
}

class EditorChecksTests {
    private fun rows(
        isEnv: Boolean = false, local: List<ComposeIssue> = emptyList(), checkError: String? = null, issues: List<ComposeIssue>? = null,
        validatedText: String? = "t", text: String = "t",
    ) = EditorChecks.rows(isEnv, "hetzner", local, checkError, issues?.let { ValidationResult(it) }, validatedText, text)

    private fun err(message: String, line: Int? = null) = ComposeIssue(ComposeIssue.Severity.ERROR, line, message)
    private fun states(r: List<EditorCheckRow>) = r.map { it.state }
    private val P = EditorCheckRow.State.PASS
    private val F = EditorCheckRow.State.FAIL
    private val S = EditorCheckRow.State.SKIPPED

    @Test fun `all pass for a valid file`() {
        val r = rows(issues = emptyList())
        assertEquals(listOf("syntax", "schema", "config"), r.map { it.id })
        assertEquals(listOf(P, P, P), states(r))
        assertTrue(r[2].detail.contains("hetzner"))
    }

    @Test fun `a syntax error skips the rest and shows the line`() {
        val r = rows(issues = listOf(err("mapping values are not allowed here", line = 4)))
        assertEquals(listOf(F, S, S), states(r))
        assertEquals("Line 4: mapping values are not allowed here", r[0].detail)
    }

    @Test fun `a schema error fails schema and skips config`() {
        assertEquals(listOf(P, F, S), states(rows(issues = listOf(err("validating compose.yaml: services.web.imagee false schema")))))
    }

    @Test fun `an interpolation error fails only the config check`() {
        assertEquals(listOf(P, P, F), states(rows(issues = listOf(err("error while interpolating services.web.image: required variable TAG is missing a value")))))
    }

    @Test fun `warnings are listed and do not fail`() {
        val r = rows(issues = listOf(ComposeIssue(ComposeIssue.Severity.WARNING, null, "version is obsolete")))
        assertEquals(listOf(P, P, P, EditorCheckRow.State.WARN), states(r))
        assertEquals("version is obsolete", r.last().detail)
    }

    @Test fun `a result for older text is never shown as current`() {
        assertEquals(listOf(EditorCheckRow.State.RUNNING), states(rows(issues = emptyList(), validatedText = "old", text = "new")))
        assertEquals(listOf(EditorCheckRow.State.RUNNING), states(rows(issues = null, validatedText = null)))
    }

    @Test fun `a check that could not run is a failure not a silent pass`() {
        val r = rows(checkError = "Rackoon can't write in the stack's folder")
        assertEquals(listOf(F), states(r))
        assertTrue(r[0].title.contains("hetzner"))
    }

    @Test fun `env files check local syntax then the compose check`() {
        val bad = rows(isEnv = true, local = listOf(err("Variable names cannot contain spaces", line = 3)))
        assertEquals(listOf("syntax", "config"), bad.map { it.id })
        assertEquals(listOf(F, S), states(bad))
        assertEquals("Line 3: Variable names cannot contain spaces", bad[0].detail)
        assertEquals(listOf(P, P), states(rows(isEnv = true, issues = emptyList())))
        assertEquals(listOf(P, F), states(rows(isEnv = true, issues = listOf(err("required variable TAG is missing a value: TAG is required")))))
    }

    @Test fun `unset variables are listed once each in order`() {
        val result = ValidationResult(
            listOf(
                ComposeIssue(ComposeIssue.Severity.WARNING, null, "The \"DB_PASSWORD\" variable is not set. Defaulting to a blank string."),
                ComposeIssue(ComposeIssue.Severity.WARNING, null, "The \"UPLOAD_LOCATION\" variable is not set. Defaulting to a blank string."),
                ComposeIssue(ComposeIssue.Severity.WARNING, null, "The \"DB_PASSWORD\" variable is not set. Defaulting to a blank string."),
                ComposeIssue(ComposeIssue.Severity.WARNING, null, "The \"bad name\" variable is not set"),
            ),
        )
        assertEquals(listOf("DB_PASSWORD", "UPLOAD_LOCATION"), result.unsetVariables)
        assertEquals(emptyList(), ValidationResult(emptyList()).unsetVariables)
    }
}
