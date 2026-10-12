package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StreamParserTests {
    private fun run(chunks: List<String>): Pair<String, Int?> {
        val p = StreamOutputParser()
        var shown = ""
        for (c in chunks) shown += p.push(c)
        val (rest, exit) = p.finish()
        return (shown + rest) to exit
    }

    @Test fun outputThenMarker() {
        val r = run(listOf("[+] Restarting 1/1\r\n", " ✔ Container web  Started\r\n", "\r\n##rackoon-exit:0\r\n"))
        assertEquals("[+] Restarting 1/1\r\n ✔ Container web  Started\r\n\r\n", r.first)
        assertEquals(0, r.second)
    }

    @Test fun markerSplitAtEveryPossiblePoint() {
        val text = "hello\r\n\r\n##rackoon-exit:17\r\n"
        for (cut in 1 until text.length) {
            val r = run(listOf(text.substring(0, cut), text.substring(cut)))
            assertEquals("hello\r\n\r\n", r.first, "cut at $cut")
            assertEquals(17, r.second, "cut at $cut")
        }
    }

    /** The exact bytes a real `ssh -tt` run produced: the marker, a CRLF, then ssh's own message. */
    @Test fun realPtyTailWithSshsOwnMessageAfterTheMarker() {
        val real = "hello\r\n\r\n##rackoon-exit:0\r\nConnection to hetzner closed.\r\n"
        val r = run(listOf(real))
        assertEquals("hello\r\n\r\n", r.first)
        assertEquals(0, r.second)
        for (cut in 1 until real.length) {
            val split = run(listOf(real.substring(0, cut), real.substring(cut)))
            assertEquals("hello\r\n\r\n", split.first, "cut at $cut")
            assertEquals(0, split.second, "cut at $cut")
        }
    }

    @Test fun multiDigitExitCodesAndNoNewlineAfterwards() {
        assertEquals(130, run(listOf("x\r\n##rackoon-exit:130\r\nbye\r\n")).second)
        assertEquals(2, run(listOf("x\n##rackoon-exit:2")).second)
    }

    @Test fun byteAtATime() {
        val r = run("one\ntwo\n##rackoon-exit:3\n".map { it.toString() })
        assertEquals("one\ntwo\n", r.first)
        assertEquals(3, r.second)
    }

    @Test fun markerWithoutATrailingNewlineStillCounts() {
        val r = run(listOf("done\n##rackoon-exit:0"))
        assertEquals("done\n", r.first)
        assertEquals(0, r.second)
    }

    @Test fun aHashInOrdinaryOutputIsNotHeldForever() {
        val r = run(listOf("## heading\n", "#", "# not a marker\n"))
        assertEquals("## heading\n## not a marker\n", r.first)
        assertNull(r.second)
    }

    @Test fun streamThatEndsWithoutAMarkerHasNoExitCode() {
        val r = run(listOf("partial output", " more"))
        assertEquals("partial output more", r.first)
        assertNull(r.second, "cancelled or dropped: unknown, never read as success")
    }

    @Test fun nothingAfterTheMarkerIsShown() {
        val r = run(listOf("a\n##rackoon-exit:1\n", "late noise\n"))
        assertEquals("a\n", r.first)
        assertEquals(1, r.second)
    }

    @Test fun wrapperCommandShape() {
        val c = StreamedCommand.wrap("cd '/srv/a' && docker compose -p a -f '/srv/a/c.yaml' restart", 100, 24)
        assertEquals("""stty cols 100 rows 24 2>/dev/null; ( cd '/srv/a' && docker compose -p a -f '/srv/a/c.yaml' restart ); rk=$?; echo; echo "##rackoon-exit:${'$'}rk"""", c)
        assertTrue(StreamedCommand.wrap("x", 1, 1).startsWith("stty cols 20 rows 5"), "sizes are clamped")
    }
}

class Utf8ChunkerTests {
    @Test fun aSplitCharacterIsJoinedAcrossChunks() {
        val bytes = "a ✔ b 😀 c".toByteArray()
        for (cut in 1 until bytes.size) {
            val c = Utf8Chunker()
            val text = c.push(bytes.copyOfRange(0, cut)) + c.push(bytes.copyOfRange(cut, bytes.size)) + c.finish()
            assertEquals("a ✔ b 😀 c", text, "cut at $cut")
        }
    }

    @Test fun byteAtATimeAndInvalidBytesDoNotHangOrLoseText() {
        val c = Utf8Chunker()
        var out = ""
        for (b in "héllo ☕ wörld 😀".toByteArray()) out += c.push(byteArrayOf(b))
        out += c.finish()
        assertEquals("héllo ☕ wörld 😀", out)
        val junk = Utf8Chunker()
        val text = junk.push(byteArrayOf(0xff.toByte(), 0xfe.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte(), 0x41)) + junk.finish()
        assertTrue(text.endsWith("A"))
    }
}

class StreamingActionTests {
    private fun stack(): DockerStack {
        val c = DockerContainer(
            id = "abcdef012345", name = "media-web-1", image = "nginx", state = "running", health = "none", status = "Up",
            ports = emptyList(), project = "media", service = "web", workingDir = "/srv/media",
            configFile = "/srv/media/compose.yaml", configFiles = listOf("/srv/media/compose.yaml"),
        )
        return DockerStack("media", "/srv/media", "/srv/media/compose.yaml", listOf("/srv/media/compose.yaml"), listOf(c), false)
    }

    private fun snapshot() = Spec.out("docker", "ubuntu-24.04-compose")

    private suspend fun runStreaming(t: FakeTransport, policy: ActionPolicy = ActionPolicy(), confirm: Boolean = true, action: ComposeAction = ComposeAction.RESTART): Pair<Collector, DockerSession> {
        val session = DockerSession(t, policy = policy)
        val got = Collector()
        val confirmation = if (confirm) runCatching { session.confirm(action, stack()) }.getOrNull() else null
        session.performStreaming(action, stack(), null, confirmation, 100, 24) { got.add(it) }
        return got to session
    }

    @Test fun streamsOutputReportsSuccessAndRefreshes() = runTest {
        val t = FakeTransport(listOf(ok(snapshot())))
        t.streamChunks = listOf("[+] Restarting 1/1\r\n", " ✔ Container web ", "Started\r\n\r\n##rack", "oon-exit:0\r\n")
        val (got, session) = runStreaming(t)
        assertEquals(listOf(StreamedCommand.wrap(ComposeAction.RESTART.command(stack())!!, 100, 24)), t.streamedCommands)
        assertEquals("[+] Restarting 1/1\r\n ✔ Container web Started\r\n\r\n", got.text)
        assertEquals(ActionStreamEvent.Finished(0), got.events.last())
        val state = session.state.value
        assertNull(state.actionError)
        assertTrue(state.busy.isEmpty() && state.busyStacks.isEmpty(), "busy is cleared when it ends")
        assertEquals(1, t.commands.size, "the list is refreshed afterwards")
        assertNotNull(state.snapshot)
    }

    @Test fun aFailingCommandIsReportedWithItsExitCode() = runTest {
        val t = FakeTransport(listOf(ok(snapshot())))
        t.streamChunks = listOf("no configuration file provided\r\n", "\r\n##rackoon-exit:1\r\n")
        val (got, session) = runStreaming(t, action = ComposeAction.PULL)
        assertEquals(ActionStreamEvent.Finished(1), got.events.last())
        assertEquals("docker compose pull failed (exit 1). The output shows why.", session.state.value.actionError)
    }

    @Test fun aStreamThatEndsWithoutAnExitCodeIsNeverASuccess() = runTest {
        val t = FakeTransport(listOf(ok(snapshot())))
        t.streamChunks = listOf("Pulling…\r\n")
        val (got, session) = runStreaming(t, action = ComposeAction.UP)
        assertEquals(ActionStreamEvent.Finished(null), got.events.last())
        assertEquals("The connection ended before docker compose up reported a result.", session.state.value.actionError)
    }

    @Test fun nothingStartsWithoutConfirmationOrInReadOnlyMode() = runTest {
        val t = FakeTransport()
        t.streamChunks = listOf("should never run")
        var (got, session) = runStreaming(t, confirm = false)
        assertTrue(t.streamedCommands.isEmpty())
        assertEquals(listOf<ActionStreamEvent>(ActionStreamEvent.Finished(null)), got.events)
        assertEquals(PolicyError.NotConfirmed.message, session.state.value.actionError)

        val second = runStreaming(t, policy = ActionPolicy(readOnly = true))
        assertTrue(t.streamedCommands.isEmpty())
        assertEquals(PolicyError.ReadOnly.message, second.second.state.value.actionError)
    }

    @Test fun containerActionsStreamToo() = runTest {
        val t = FakeTransport(listOf(ok(snapshot())))
        t.streamChunks = listOf("abcdef012345\r\n", "\r\n##rackoon-exit:0\r\n")
        val session = DockerSession(t)
        val got = Collector()
        val confirmation = session.confirm(DockerAction.RESTART, "abcdef012345")
        session.performStreaming(DockerAction.RESTART, "abcdef012345", confirmation, 90, 20) { got.add(it) }
        assertEquals(listOf(StreamedCommand.wrap("docker restart abcdef012345", 90, 20)), t.streamedCommands)
        assertEquals("abcdef012345\r\n\r\n", got.text)
        assertEquals(ActionStreamEvent.Finished(0), got.events.last())
        val state = session.state.value
        assertTrue(state.busy.isEmpty())
        assertNull(state.actionError)
        assertEquals(1, t.commands.size, "refreshed afterwards")
    }

    @Test fun containerStreamingRefusesBadIdsAndMissingConfirmation() = runTest {
        val t = FakeTransport()
        t.streamChunks = listOf("should never run")
        val session = DockerSession(t)
        val got = Collector()
        session.performStreaming(DockerAction.STOP, "x; reboot", null, 80, 24) { got.add(it) }
        session.performStreaming(DockerAction.STOP, "abcdef012345", null, 80, 24) { got.add(it) }
        assertTrue(t.streamedCommands.isEmpty())
        assertEquals(listOf<ActionStreamEvent>(ActionStreamEvent.Finished(null), ActionStreamEvent.Finished(null)), got.events)
        assertEquals(PolicyError.NotConfirmed.message, session.state.value.actionError)
    }

    @Test fun sentinelLookalikesInOutputDoNotEndTheRunEarly() = runTest {
        val t = FakeTransport(listOf(ok(snapshot())))
        t.streamChunks = listOf("service says: ##rackoon-exit is a marker name\r\n", "real output\r\n\r\n##rackoon-exit:0\r\n")
        val (got, _) = runStreaming(t)
        assertEquals(ActionStreamEvent.Finished(0), got.events.last())
    }
}

class AptStreamingTests {
    private fun read(name: String) = Spec.out("updates", name)

    @Test fun streamsAptThenRereadsTheList() = runTest {
        val t = FakeTransport(listOf(ok(read("ubuntu-24.04-current"))))
        t.streamChunks = listOf("Reading package lists... Done\r\n", "\u001B[1mProgress: [ 50%]\u001B[0m\r", "\r\n##rackoon-exit:0\r\n")
        val session = UpdatesSession(t)
        val got = Collector()
        val action = AptAction.Upgrade(listOf("openssl"))
        session.performStreaming(action, session.confirm(action), 100, 24) { got.add(it) }
        assertEquals(listOf(StreamedCommand.wrap(action.command!!, 100, 24)), t.streamedCommands)
        assertTrue(got.text.contains("Reading package lists"))
        assertEquals(ActionStreamEvent.Finished(0), got.events.last())
        val state = session.state.value
        assertFalse(state.isWorking)
        assertNull(state.actionError)
        assertEquals(true, state.actionOutput?.contains("Progress: [ 50%]"), "the done message is plain text, no escapes")
        assertEquals(false, state.actionOutput?.contains("\u001B"))
        assertEquals(0, state.snapshot?.packages?.size, "the list is re-read afterwards")
    }

    @Test fun sudoAndLockFailuresAreExplainedFromTheStreamedText() = runTest {
        for ((output, expected) in listOf(
            "sudo: a password is required\r\n" to "passwordless sudo",
            "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 1234\r\n" to "lock",
        )) {
            val t = FakeTransport(listOf(ok(read("synthetic-security-pending"))))
            t.streamChunks = listOf(output, "\r\n##rackoon-exit:1\r\n")
            val session = UpdatesSession(t)
            val got = Collector()
            session.performStreaming(AptAction.Refresh, session.confirm(AptAction.Refresh), 80, 24) { got.add(it) }
            val state = session.state.value
            assertTrue(state.actionError?.contains(expected) == true, state.actionError ?: "null")
            assertEquals(ActionStreamEvent.Finished(1), got.events.last())
            assertEquals(3, state.snapshot?.securityCount, "the list still refreshes after a failure")
        }
    }

    @Test fun anEndedStreamWithoutAnExitCodeIsAFailure() = runTest {
        val t = FakeTransport(listOf(ok(read("ubuntu-24.04-current"))))
        t.streamChunks = listOf("Get:1 http://archive.ubuntu.com noble InRelease\r\n")
        val session = UpdatesSession(t)
        session.performStreaming(AptAction.UpgradeAll, session.confirm(AptAction.UpgradeAll), 80, 24) {}
        assertEquals("The connection ended before apt reported a result.", session.state.value.actionError)
    }

    @Test fun nothingStartsWithoutConfirmationOrInReadOnlyMode() = runTest {
        val t = FakeTransport()
        t.streamChunks = listOf("should never run")
        val session = UpdatesSession(t)
        val got = Collector()
        session.performStreaming(AptAction.UpgradeAll, null, 80, 24) { got.add(it) }
        assertTrue(t.streamedCommands.isEmpty())
        assertEquals(listOf<ActionStreamEvent>(ActionStreamEvent.Finished(null)), got.events)
        assertEquals(PolicyError.NotConfirmed.message, session.state.value.actionError)
        val ro = UpdatesSession(t, ActionPolicy(readOnly = true))
        ro.performStreaming(AptAction.Refresh, null, 80, 24) {}
        assertEquals(PolicyError.ReadOnly.message, ro.state.value.actionError)
        assertTrue(t.streamedCommands.isEmpty())
        ro.performStreaming(AptAction.Upgrade(listOf("x; reboot")), null, 80, 24) {}
        assertTrue(t.streamedCommands.isEmpty())
    }

    @Test fun ansiStripping() {
        assertEquals("ok\nline", ANSI.strip("\u001B[1;32mok\u001B[0m\r\n\u001B[2K\u001B[1Aline\u001B[?25l"))
        assertEquals("plain", ANSI.strip("plain"))
    }
}
