package com.bgallagher.rackoon.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A tiny fake server for one stack's files: answers reads, checks and saves from an in-memory map, and counts what it was asked. */
private class FakeFiles(var composeText: String = "services:\n  web:\n    image: nginx\n") : SSHTransport {
    var envText: String? = null
    var checks = 0
    var rejectWith: String? = null
    var changeUnderneath = false
    private fun sha(t: String) = java.security.MessageDigest.getInstance("SHA-256").digest(t.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun content(c: String): String {
        val b64 = Regex("""echo '([A-Za-z0-9+/=]*)' \| base64 -d""").find(c)?.groupValues?.get(1).orEmpty()
        return if (b64.isEmpty()) "" else String(java.util.Base64.getDecoder().decode(b64))
    }
    override suspend fun run(command: String, timeoutMillis: Long): CommandResult = when {
        command.startsWith("F='") && command.contains("echo '##meta'") -> {
            val text = if (command.contains(".env'")) envText else composeText
            if (text == null) CommandResult("##missing\n") else CommandResult("##meta\n1700000000 644 root:root\n##sha256\n${sha(text)}\n##content\n${java.util.Base64.getEncoder().encodeToString(text.toByteArray())}\n")
        }
        command.contains(".rackoon-check.") -> { checks++; rejectWith?.let { CommandResult("$it\n", exitCode = 1) } ?: CommandResult("") }
        command.contains("echo '##saved'") -> {
            if (changeUnderneath) CommandResult("##changed\n", exitCode = 3)
            else { val t = content(command); if (command.contains("/.env")) envText = t else composeText = t; CommandResult("##saved\n${sha(t)}\n") }
        }
        else -> CommandResult("")
    }
    override fun stream(command: String) = kotlinx.coroutines.flow.emptyFlow<String>()
}

@OptIn(ExperimentalCoroutinesApi::class)
class StackEditorTests {
    private val compose = EditableFile.Compose("/srv/media/compose.yaml")
    private val env = EditableFile.Env("/srv/media/.env")

    private fun stack(): DockerStack {
        val c = DockerContainer(
            id = "abcdef012345", name = "media-web-1", image = "nginx", state = "running", health = "none", status = "Up", ports = emptyList(),
            project = "media", service = "web", workingDir = "/srv/media", configFile = "/srv/media/compose.yaml", configFiles = listOf("/srv/media/compose.yaml"),
        )
        return DockerStack("media", "/srv/media", "/srv/media/compose.yaml", listOf("/srv/media/compose.yaml"), listOf(c), false)
    }

    private class Setup(val editor: StackEditor, val server: FakeFiles, val policy: ActionPolicy)

    private fun TestScope.setup(server: FakeFiles = FakeFiles(), readOnly: Boolean = false): Setup {
        val policy = ActionPolicy(readOnly)
        val editor = StackEditor(StackFileSession(server, stack(), policy), stack(), "hetzner", this, { policy.isReadOnly })
        return Setup(editor, server, policy)
    }

    @Test fun `opening reads the file and a clean draft has no checks`() = runTest {
        val s = setup()
        s.editor.open(compose)
        advanceUntilIdle()
        val d = s.editor.state.value.drafts.getValue(compose)
        assertEquals("services:\n  web:\n    image: nginx\n", d.text)
        assertFalse(d.isDirty)
        assertEquals(emptyList(), s.editor.rows(compose))
        assertEquals("No changes to save", s.editor.saveBlockedReason(compose))
        s.editor.close()
    }

    @Test fun `a missing env file opens empty and can be created`() = runTest {
        val s = setup()
        s.editor.open(env)
        advanceUntilIdle()
        assertEquals(RemoteFileState.Missing, s.editor.state.value.drafts.getValue(env).original)
        s.editor.setText(env, "TZ=Europe/Dublin\n")
        advanceUntilIdle()
        assertTrue(s.editor.canSave(env))
        val edit = s.editor.editFor(env)!!
        assertNull(edit.originalSHA, "a new file is saved with the not-exists guard")
        s.editor.save(edit, redeploy = false)
        advanceUntilIdle()
        assertEquals("TZ=Europe/Dublin\n", s.server.envText)
        assertFalse(s.editor.isDirty(env), "after saving, the saved text is the new original")
        s.editor.close()
    }

    @Test fun `typing waits for a pause then checks the exact current text`() = runTest {
        val s = setup()
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "services:\n  web:\n    image: nginx:1\n")
        assertTrue(s.editor.state.value.drafts.getValue(compose).checking)
        assertEquals(listOf(EditorCheckRow.State.RUNNING), s.editor.rows(compose).map { it.state })
        assertFalse(s.editor.canSave(compose), "not before the check passed")
        advanceTimeBy(500); assertEquals(0, s.server.checks, "still waiting for a pause in typing")
        advanceUntilIdle()
        assertEquals(1, s.server.checks)
        assertTrue(s.editor.canSave(compose))
        assertNull(s.editor.saveBlockedReason(compose))
        s.editor.close()
    }

    @Test fun `fast typing makes one check and the newest text wins`() = runTest {
        val s = setup()
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "a: 1\n")
        advanceTimeBy(300)
        s.editor.setText(compose, "a: 2\n")
        advanceTimeBy(300)
        s.editor.setText(compose, "a: 3\n")
        advanceUntilIdle()
        assertEquals(1, s.server.checks, "earlier keystrokes never reached the server")
        assertEquals("a: 3\n", s.editor.state.value.drafts.getValue(compose).validatedText)
        s.editor.close()
    }

    @Test fun `editing after a passed check makes the old result stale`() = runTest {
        val s = setup()
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "a: 1\n"); advanceUntilIdle()
        assertTrue(s.editor.canSave(compose))
        s.editor.setText(compose, "a: 12\n")
        assertFalse(s.editor.canSave(compose), "a result for older text is never the verdict on this text")
        assertEquals("Waiting for the check on hetzner", s.editor.saveBlockedReason(compose))
        s.editor.close()
    }

    @Test fun `server errors block saving and mark their lines`() = runTest {
        val s = setup(FakeFiles().also { it.rejectWith = "yaml: line 3: mapping values are not allowed here" })
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "services:\n  web:\n    image nginx\n"); advanceUntilIdle()
        assertFalse(s.editor.canSave(compose))
        assertEquals(setOf(3), s.editor.state.value.drafts.getValue(compose).errorLines)
        assertEquals("Fix the errors above first", s.editor.saveBlockedReason(compose))
        assertEquals(EditorCheckRow.State.FAIL, s.editor.rows(compose).first().state)
        s.editor.close()
    }

    @Test fun `env syntax errors are found locally without asking the server`() = runTest {
        val s = setup()
        s.editor.open(env); advanceUntilIdle()
        s.editor.setText(env, "GOOD=1\nBAD LINE\n"); advanceUntilIdle()
        assertEquals(0, s.server.checks)
        assertEquals("Fix the syntax error first", s.editor.saveBlockedReason(env))
        assertEquals(setOf(2), s.editor.state.value.drafts.getValue(env).errorLines)
        s.editor.close()
    }

    @Test fun `read-only mode blocks saving even after a passed check`() = runTest {
        val s = setup()
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "a: 1\n"); advanceUntilIdle()
        assertTrue(s.editor.canSave(compose))
        s.policy.isReadOnly = true
        assertFalse(s.editor.canSave(compose))
        assertEquals("Read-only mode is on", s.editor.saveBlockedReason(compose))
        assertNull(s.editor.editFor(compose))
        s.editor.close()
    }

    @Test fun `a save writes the file and runs the redeploy callback`() = runTest {
        val s = setup()
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "services:\n  web:\n    image: nginx:2\n"); advanceUntilIdle()
        val edit = s.editor.editFor(compose)!!
        assertTrue(s.editor.intent(edit)!!.preview!!.contains("+     image: nginx:2"))
        var deployed = false
        s.editor.save(edit, redeploy = true) { deployed = true }
        advanceUntilIdle()
        assertTrue(deployed)
        assertEquals("services:\n  web:\n    image: nginx:2\n", s.server.composeText)
        assertEquals(EditorNotice.Saved("compose.yaml", true), s.editor.state.value.notice)
        assertFalse(s.editor.isDirty(compose))
        s.editor.close()
    }

    @Test fun `a file changed on the server is not overwritten and can be reloaded`() = runTest {
        val s = setup()
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "a: 1\n"); advanceUntilIdle()
        val edit = s.editor.editFor(compose)!!
        s.server.changeUnderneath = true
        var deployed = false
        s.editor.save(edit, redeploy = true) { deployed = true }
        advanceUntilIdle()
        assertFalse(deployed, "no redeploy after a refused save")
        assertEquals(EditorNotice.ChangedOnServer(compose), s.editor.state.value.notice)
        assertTrue(s.editor.isDirty(compose), "the draft is kept (Keep Editing)")
        assertEquals("services:\n  web:\n    image: nginx\n", s.server.composeText)
        // Reload from Server throws the draft away and reads again.
        s.server.changeUnderneath = false
        s.server.composeText = "services:\n  web:\n    image: nginx:from-server\n"
        s.editor.reload(compose); advanceUntilIdle()
        assertEquals("services:\n  web:\n    image: nginx:from-server\n", s.editor.state.value.drafts.getValue(compose).text)
        assertFalse(s.editor.isDirty(compose))
        assertNull(s.editor.state.value.notice)
        s.editor.close()
    }

    @Test fun `revert goes back to what the server had and clears the checks`() = runTest {
        val s = setup()
        s.editor.open(compose); advanceUntilIdle()
        s.editor.setText(compose, "a: 1\n"); advanceUntilIdle()
        assertTrue(s.editor.hasUnsavedChanges)
        s.editor.revert(compose); advanceUntilIdle()
        assertFalse(s.editor.hasUnsavedChanges)
        assertEquals(emptyList(), s.editor.rows(compose))
        assertNotNull(s.editor.state.value.drafts[compose])
        s.editor.close()
    }

    @Test fun `a file that is too large is reported not edited`() = runTest {
        val server = object : SSHTransport {
            override suspend fun run(command: String, timeoutMillis: Long) = CommandResult("##toolarge\n")
            override fun stream(command: String) = kotlinx.coroutines.flow.emptyFlow<String>()
        }
        val policy = ActionPolicy()
        val editor = StackEditor(StackFileSession(server, stack(), policy), stack(), "hetzner", this, { false })
        editor.open(compose); advanceUntilIdle()
        assertEquals(StackFileError.TooLarge.message, editor.state.value.drafts.getValue(compose).loadError)
        editor.close()
    }
}
