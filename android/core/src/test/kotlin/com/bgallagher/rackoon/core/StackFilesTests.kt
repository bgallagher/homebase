package com.bgallagher.rackoon.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StackFileParserTests {
    private fun parsed(text: String): JsonElement = try {
        when (val s = RemoteFileParser.parse(text)) {
            RemoteFileState.Missing -> buildJsonObject { put("state", "missing") }
            RemoteFileState.TooLarge -> buildJsonObject { put("state", "tooLarge") }
            is RemoteFileState.File -> buildJsonObject {
                put("state", "file"); put("content", s.file.content); put("sha256", s.file.sha256)
                put("mode", s.file.mode); put("owner", s.file.owner); put("modifiedAt", s.file.modifiedAt)
            }
        }
    } catch (e: StackFileError.NotText) {
        buildJsonObject { put("error", "notText") }
    } catch (e: Exception) {
        buildJsonObject { put("error", "other"); put("message", e.message ?: "") }
    }

    /** Every fixture in spec/fixtures/file_read must parse to its expected JSON (shared with the Swift core). */
    @Test fun `golden fixtures`() {
        val names = Spec.fixtures("file_read")
        assertTrue(names.size >= 7)
        for (name in names) {
            val diff = jsonDiff(Spec.expected("file_read", name), parsed(Spec.out("file_read", name)))
            assertNull(diff, "$name: $diff")
        }
    }

    @Test fun `CRLF and a missing trailing newline survive exactly`() {
        val crlf = RemoteFileParser.parse(Spec.out("file_read", "unicode-and-crlf"))
        assertTrue(crlf.content!!.contains("\r\n"))
        val env = RemoteFileParser.parse(Spec.out("file_read", "env-no-trailing-newline"))
        assertTrue(env.content!!.endsWith("info"), "no newline was added")
    }

    @Test fun `broken output is malformed not empty`() {
        assertEquals(StackFileError.Malformed("no ##meta"), assertFailsWith<StackFileError.Malformed> { RemoteFileParser.parse("") })
        assertFailsWith<StackFileError> { RemoteFileParser.parse("##meta\n1 644 root:root\n##sha256\nabc\n##content\nAAAA\n") }
        assertFailsWith<StackFileError> { RemoteFileParser.parse("##meta\n1 644 root:root\n##sha256\n${"a".repeat(64)}\n##content\n!!!notbase64\n") }
    }
}

class ComposeIssueParserTests {
    @Test fun `yaml syntax error has its line`() {
        assertEquals(
            listOf(ComposeIssue(ComposeIssue.Severity.ERROR, 5, "could not find expected ':'")),
            ComposeIssueParser.parse("yaml: line 5: could not find expected ':'\n"),
        )
    }

    @Test fun `indented unmarshal lines and schema errors`() {
        val issues = ComposeIssueParser.parse(
            "yaml: unmarshal errors:\n  line 3: field imagee not found in type types.ServiceConfig\n" +
                "validating /srv/a/compose.yaml: services.web Additional property foo is not allowed",
        )
        assertEquals(listOf(null, 3, null), issues.map { it.line })
        assertTrue(issues.all { it.severity == ComposeIssue.Severity.ERROR })
        assertEquals("field imagee not found in type types.ServiceConfig", issues[1].message)
    }

    @Test fun `newer compose error format has its line and the temp name is replaced`() {
        val raw = ComposeIssueParser.parse("failed to parse /srv/a/.rackoon-check.AfWne0: go-yaml load error in scanner at L4.C12: mapping values are not allowed in this context\n")
        assertEquals(4, raw.first().line)
        assertEquals("mapping values are not allowed in this context", raw.first().message)
        val schema = ComposeIssueParser.parse("validating /srv/a/.rackoon-save.y1DKDz: services.web.imagee false schema\n")[0]
        assertEquals("validating compose.yaml: services.web.imagee false schema", schema.naming(EditableFile.Compose("/srv/a/compose.yaml")).message)
        val parse = ComposeIssueParser.parse("failed to parse /srv/a/.rackoon-save.y1DKDz: bad\n")[0]
        assertEquals("failed to parse .env: bad", parse.naming(EditableFile.Env("/srv/a/.env")).message)
    }

    @Test fun `warnings are not errors`() {
        val issues = ComposeIssueParser.parse("""time="2026-10-10T03:08:33Z" level=warning msg="/opt/stacks/monitoring/compose.yaml: the attribute `version` is obsolete, it will be ignored"""" + "\n")
        assertEquals(1, issues.size)
        assertEquals(ComposeIssue.Severity.WARNING, issues[0].severity)
        assertTrue(issues[0].message.endsWith("it will be ignored"))
        assertTrue(ValidationResult(issues).isValid)
    }

    @Test fun `markers and blank lines are ignored`() {
        assertEquals(emptyList(), ComposeIssueParser.parse("##invalid\n\n   \n"))
    }
}

class LineDiffTests {
    @Test fun `changed added removed and same`() {
        val old = "a\nb\nc\n"
        val new = "a\nB\nc\nd\n"
        assertEquals(setOf(2, 4), LineDiff.changedLineNumbers(old, new))
        assertEquals(3, LineDiff.changeCount(old, new), "b removed, B added, d added")
        assertEquals(0, LineDiff.changeCount(old, old))
        assertEquals(listOf(LineDiff.Kind.ADDED), LineDiff.lines("", "x\n").map { it.kind })
        assertEquals(listOf(LineDiff.Kind.REMOVED), LineDiff.lines("x\n", "").map { it.kind })
    }

    @Test fun `a trailing newline is not a change`() {
        assertEquals(0, LineDiff.changeCount("a\nb", "a\nb\n"))
    }

    @Test fun `preview shows only changes with context`() {
        val old = (1..20).joinToString("\n") { "line$it" } + "\n"
        val new = old.replace("line10\n", "changed\n")
        val preview = LineDiff.preview(old, new)
        assertTrue(preview.contains("- line10"))
        assertTrue(preview.contains("+ changed"))
        assertTrue(preview.contains("  line8"))
        assertFalse(preview.contains("line1\n"), "far-away lines are left out")
        assertEquals("No changes.", LineDiff.preview(old, old))
    }

    /** Whatever the inputs, same+added rebuild the new text and same+removed the old one, with consistent 1-based numbers. */
    @Test fun `the diff always rebuilds both sides`() {
        val random = Random(42)
        val alphabet = listOf("a", "b", "c", "", "  x", "y")
        repeat(300) {
            val old = List(random.nextInt(0, 13)) { alphabet.random(random) }
            val new = List(random.nextInt(0, 13)) { alphabet.random(random) }
            val oldText = if (old.isEmpty()) "" else old.joinToString("\n") + "\n"
            val newText = if (new.isEmpty()) "" else new.joinToString("\n") + "\n"
            val lines = LineDiff.lines(oldText, newText)
            assertEquals(new, lines.filter { it.kind != LineDiff.Kind.REMOVED }.map { it.text }, "new side for $old -> $new")
            assertEquals(old, lines.filter { it.kind != LineDiff.Kind.ADDED }.map { it.text }, "old side for $old -> $new")
            assertEquals((1..new.size).toList(), lines.mapNotNull { it.newNumber })
            assertEquals((1..old.size).toList(), lines.mapNotNull { it.oldNumber })
        }
    }
}

private val sha = "a".repeat(64)

private fun stack(files: List<String> = listOf("/srv/media/compose.yaml"), dir: String = "/srv/media", standalone: Boolean = false): DockerStack {
    val c = DockerContainer(
        id = "abcdef012345", name = "media-web-1", image = "nginx", state = "running", health = "none", status = "Up", ports = emptyList(),
        project = "media", service = "web", workingDir = dir, configFile = files.first(), configFiles = files,
    )
    return DockerStack("media", dir, files.first(), files, listOf(c), standalone)
}

class StackFileCommandTests {
    @Test fun `editable files are compose files then env`() {
        val s = stack(files = listOf("/srv/media/compose.yaml", "/srv/media/compose.override.yaml"))
        assertEquals(
            listOf(EditableFile.Compose("/srv/media/compose.yaml"), EditableFile.Compose("/srv/media/compose.override.yaml"), EditableFile.Env("/srv/media/.env")),
            StackFiles.editable(s),
        )
        assertEquals(listOf(EditableFile.Compose("/srv/media/compose.yaml"), EditableFile.Env("/srv/media/.env")), StackFiles.editable(stack(dir = "/srv/media/")))
        assertNull(StackFiles.editable(stack(standalone = true).copy(workingDir = null)))
    }

    @Test fun `only the stacks own files can be touched`() {
        val s = stack()
        for (evil in listOf(EditableFile.Compose("/etc/passwd"), EditableFile.Env("/etc/shadow"), EditableFile.Compose("/srv/media/../../etc/passwd"), EditableFile.Env("/srv/media/other.env"))) {
            assertNull(StackFileCommands.read(evil, s), evil.path)
            assertNull(StackFileCommands.validate(evil, "x", s), evil.path)
            assertNull(StackFileCommands.write(evil, "x", null, s), evil.path)
        }
        assertNotNull(StackFileCommands.read(EditableFile.Compose("/srv/media/compose.yaml"), s))
        assertNotNull(StackFileCommands.read(EditableFile.Env("/srv/media/.env"), s))
    }

    @Test fun `validate swaps the edited compose file for the temp file`() {
        val s = stack(files = listOf("/srv/media/compose.yaml", "/srv/media/compose.override.yaml"))
        val c = StackFileCommands.validate(EditableFile.Compose("/srv/media/compose.override.yaml"), "services: {}\n", s)!!
        assertTrue(c.contains("""-f '/srv/media/compose.yaml' -f "${'$'}T" config -q"""), c)
        assertFalse(c.contains("--env-file"))
        val env = StackFileCommands.validate(EditableFile.Env("/srv/media/.env"), "A=1\n", s)!!
        assertTrue(env.contains("""--env-file "${'$'}T" -f '/srv/media/compose.yaml' -f '/srv/media/compose.override.yaml' config -q"""), env)
    }

    @Test fun `content travels as quoted base64 and round trips`() {
        val content = "services:\n  web:\n    image: \"it's \$(whoami) `id`; rm -rf /\"\n"
        val c = StackFileCommands.validate(EditableFile.Compose("/srv/media/compose.yaml"), content, stack())!!
        assertFalse(c.contains("whoami"), "content must never appear in the command as text")
        val encoded = Regex("""echo '([A-Za-z0-9+/=]*)' \| base64""").find(c)!!.groupValues[1]
        assertEquals(content, String(java.util.Base64.getDecoder().decode(encoded), Charsets.UTF_8))
    }

    @Test fun `write guards against changes and new files`() {
        val existing = StackFileCommands.write(EditableFile.Compose("/srv/media/compose.yaml"), "x\n", sha, stack())!!
        assertTrue(existing.contains("= '$sha' ] || { echo '##changed'; exit 3; }"))
        assertTrue(existing.contains("cp -p \"${'$'}F\" \"${'$'}F.rackoon.bak\""))
        assertTrue(existing.contains("mv -f \"${'$'}T\" \"${'$'}F\""))
        // validation comes before the backup and the move
        assertTrue(existing.indexOf("config -q") < existing.indexOf("mv -f"))
        val new = StackFileCommands.write(EditableFile.Env("/srv/media/.env"), "A=1\n", null, stack())!!
        assertTrue(new.contains("""[ ! -e "${'$'}F" ] || { echo '##changed'; exit 3; }"""))
        for (bad in listOf("", "abc", "A".repeat(64), "a".repeat(63) + "'")) {
            assertNull(StackFileCommands.write(EditableFile.Compose("/srv/media/compose.yaml"), "x", bad, stack()), bad)
        }
    }

    @Test fun `an empty file can be validated and saved`() {
        val c = StackFileCommands.validate(EditableFile.Env("/srv/media/.env"), "", stack())!!
        assertTrue(c.contains("echo '' | base64 -d"), c)
        assertNotNull(StackFileCommands.write(EditableFile.Env("/srv/media/.env"), "", sha, stack()))
    }

    @Test fun `size cap and placeholder lookalikes in paths`() {
        assertNotNull(StackFileCommands.validate(EditableFile.Compose("/srv/media/compose.yaml"), "a".repeat(StackFiles.MAX_BYTES), stack()))
        assertNull(StackFileCommands.validate(EditableFile.Compose("/srv/media/compose.yaml"), "a".repeat(StackFiles.MAX_BYTES + 1), stack()))
        // A path containing placeholder text is inserted literally, never substituted again.
        val tricky = stack(files = listOf("/srv/{b64}/compose.yaml"), dir = "/srv/{b64}")
        val c = StackFileCommands.read(EditableFile.Compose("/srv/{b64}/compose.yaml"), tricky)!!
        assertTrue(c.startsWith("F='/srv/{b64}/compose.yaml';"), c)
    }
}

class StackFileSessionTests {
    private val file = EditableFile.Compose("/srv/media/compose.yaml")
    private val shaB = "b".repeat(64)

    private fun edit(content: String = "services:\n  web:\n    image: nginx:1\n") =
        FileEdit(file, "services:\n  web:\n    image: nginx\n", shaB, content)

    @Test fun `read parses and refuses foreign files`() = runBlocking {
        val t = FakeTransport(listOf(ok(Spec.out("file_read", "compose-normal"))))
        val session = StackFileSession(t, stack())
        assertTrue(session.read(file).content!!.startsWith("services:"))
        val e = assertFailsWith<StackFileError.NotEditable> { session.read(EditableFile.Compose("/etc/passwd")) }
        assertEquals(StackFileError.NotEditable("/etc/passwd"), e)
        assertEquals(1, t.commands.size, "the foreign read never reached the server")
    }

    @Test fun `validate maps output to issues and never reads failure as valid`() = runBlocking {
        var result = StackFileSession(FakeTransport(listOf(ok("yaml: line 5: could not find expected ':'\n", exitCode = 1))), stack()).validate(file, "x")
        assertEquals(5, result.errors.first().line)
        assertFalse(result.isValid)

        result = StackFileSession(FakeTransport(listOf(ok("time=\"t\" level=warning msg=\"version is obsolete\"\n"))), stack()).validate(file, "x")
        assertTrue(result.isValid)
        assertEquals(1, result.warnings.size)

        result = StackFileSession(FakeTransport(listOf(ok("", "docker: command not found", 127))), stack()).validate(file, "x")
        assertFalse(result.isValid, "a failure with no parseable error is still a failure")
        assertTrue(result.errors.first().message.contains("command not found"))

        assertFailsWith<StackFileError.CannotWrite> { StackFileSession(FakeTransport(listOf(ok("##cannot-write\n", exitCode = 7))), stack()).validate(file, "x") }
        Unit
    }

    @Test fun `save needs confirmation and honours read-only`() = runBlocking {
        val t = FakeTransport(emptyList())
        val session = StackFileSession(t, stack())
        assertFailsWith<PolicyError.NotConfirmed> { session.save(edit(), null) }
        // A confirmation for one edit cannot save a different one.
        val confirmed = session.confirm(edit("a: 1\n"))
        assertFailsWith<PolicyError.NotConfirmed> { session.save(edit("b: 2\n"), confirmed) }

        val ro = StackFileSession(t, stack(), ActionPolicy(readOnly = true))
        assertFailsWith<PolicyError.ReadOnly> { ro.confirm(edit()) }
        assertTrue(t.commands.isEmpty())
        Unit
    }

    @Test fun `the intent preview is the diff not the command`() {
        val intent = StackFileSession(FakeTransport(emptyList()), stack()).intent(edit())!!
        assertEquals(Risk.MUTATE, intent.risk)
        assertTrue(intent.preview!!.contains("+     image: nginx:1"), intent.preview)
        assertTrue(intent.preview!!.contains("-     image: nginx"))
        assertEquals(2, edit().changeCount)
    }

    private suspend fun outcome(r: Result<CommandResult>): SaveOutcome {
        val session = StackFileSession(FakeTransport(listOf(r)), stack())
        return session.save(edit(), session.confirm(edit()))
    }

    @Test fun `save outcomes`() = runBlocking {
        val newSHA = "c".repeat(64)
        assertEquals(SaveOutcome.Saved(newSHA), outcome(ok("##saved\n$newSHA\n")))
        assertEquals(SaveOutcome.ChangedOnServer, outcome(ok("##changed\n", exitCode = 3)))
        assertEquals(
            SaveOutcome.Invalid(listOf(ComposeIssue(ComposeIssue.Severity.ERROR, 3, "mapping values are not allowed here"))),
            outcome(ok("##invalid\nyaml: line 3: mapping values are not allowed here\n", exitCode = 4)),
        )
        assertFailsWith<StackFileError.CannotWrite> { outcome(ok("##cannot-write\n", exitCode = 7)) }
        val e = assertFailsWith<StackFileError.Malformed> { outcome(ok("", exitCode = 0)) }
        assertEquals("save did not confirm", e.detail)
        Unit
    }

    @Test fun `too large content is refused before anything is sent`() = runBlocking {
        val t = FakeTransport(emptyList())
        val session = StackFileSession(t, stack())
        val big = edit("a".repeat(StackFiles.MAX_BYTES + 1))
        assertFailsWith<StackFileError.TooLarge> { session.save(big, null) }
        assertFailsWith<StackFileError.TooLarge> { session.validate(file, big.content) }
        assertTrue(t.commands.isEmpty())
        Unit
    }
}
