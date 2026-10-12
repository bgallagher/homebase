package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DockerSessionTests {
    private fun fixture(name: String) = Spec.out("docker", name)

    @Test fun commandsMatchSpec() {
        val commands = ((Spec.parse("commands.json") as JsonObject)["commands"] as JsonArray).map { it as JsonObject }
        fun script(id: String) = commands.firstOrNull { it["id"]!!.jsonPrimitive.content == id }?.get("script")?.jsonPrimitive?.content
        assertEquals(script("docker"), DockerSession.command)
        for (action in DockerAction.entries) {
            assertEquals("docker ${action.raw} {id}", script("docker_${action.raw}"))
            assertEquals("docker ${action.raw} abcdef012345", DockerSession.actionCommand(action, "abcdef012345"))
        }
        assertEquals("docker logs -f --tail 100 {id}", script("docker_logs"))
        assertEquals("docker logs -f --tail 100 abcdef012345", DockerSession.logsCommand("abcdef012345"))
        assertNull(DockerSession.logsCommand("abcdef012345 && reboot"))
    }

    @Test fun actionRejectsAnythingButAHexID() {
        for (bad in listOf("", "abc", "abcdef012345; rm -rf /", "ABCDEF012345", "abcdef01234g", "$(whoami)abcdef", "a b c d e f 0 1 2 3 4 5", "a".repeat(65))) {
            assertNull(DockerSession.actionCommand(DockerAction.RESTART, bad), bad)
        }
        assertNotNull(DockerSession.actionCommand(DockerAction.STOP, "a".repeat(64)))
    }

    @Test fun refreshPublishesSnapshot() = runTest {
        val session = DockerSession(FakeTransport(listOf(ok(fixture("ubuntu-24.04-compose")))))
        session.refresh()
        assertEquals(8, session.state.value.snapshot?.containers?.size)
        assertNull(session.state.value.error)
    }

    @Test fun notInstalledAndDaemonErrorsKeepLastSnapshot() = runTest {
        val session = DockerSession(
            FakeTransport(listOf(ok(fixture("ubuntu-24.04-compose")), ok(fixture("synthetic-permission-denied")), ok(fixture("synthetic-docker-missing")))),
        )
        session.refresh()
        session.refresh()
        assertNotNull(session.state.value.snapshot, "last good data stays")
        assertTrue(session.state.value.error?.contains("permission denied") == true)
        session.refresh()
        assertEquals("Docker is not installed on this server.", session.state.value.error)
    }

    @Test fun restartRunsCommandThenRefreshes() = runTest {
        val transport = FakeTransport(listOf(ok("abcdef012345\n"), ok(fixture("ubuntu-24.04-compose"))))
        val session = DockerSession(transport)
        session.perform(DockerAction.RESTART, "abcdef012345", session.confirm(DockerAction.RESTART, "abcdef012345"))
        assertEquals("docker restart abcdef012345", transport.commands.first())
        assertEquals(2, transport.commands.size)
        assertTrue(session.state.value.busy.isEmpty())
        assertNull(session.state.value.actionError)
        assertNotNull(session.state.value.snapshot)
    }

    @Test fun failedActionIsReportedAndInvalidIDNeverRuns() = runTest {
        val transport = FakeTransport(listOf(ok("", "Error: No such container", 1), ok(fixture("ubuntu-24.04-compose"))))
        val session = DockerSession(transport)
        session.perform(DockerAction.STOP, "abcdef012345", session.confirm(DockerAction.STOP, "abcdef012345"))
        assertEquals("Error: No such container", session.state.value.actionError)

        session.perform(DockerAction.STOP, "x; reboot", runCatching { session.confirm(DockerAction.STOP, "x; reboot") }.getOrNull())
        assertEquals(2, transport.commands.size, "invalid id was not sent")
        assertTrue(session.state.value.actionError?.contains("invalid container id") == true)
    }

    @Test fun composeActionsUseTheStacksOwnFilesAndRefuseUnsafeOnes() {
        val c = DockerContainer(
            id = "abcdef012345", name = "n", image = "i", state = "running", health = "none", status = "Up", ports = emptyList(),
            project = "media", service = "web", workingDir = "/srv/my media", configFile = "/srv/my media/compose.yaml",
            configFiles = listOf("/srv/my media/compose.yaml", "/srv/my media/extra.yaml"),
        )
        val stack = DockerSnapshot(listOf(c)).stacks.single()
        assertEquals(
            "cd '/srv/my media' && docker compose -p media -f '/srv/my media/compose.yaml' -f '/srv/my media/extra.yaml' up -d",
            ComposeAction.UP.command(stack),
        )
        assertEquals(
            "cd '/srv/my media' && docker compose -p media -f '/srv/my media/compose.yaml' -f '/srv/my media/extra.yaml' up -d --build --no-deps web",
            ComposeAction.REBUILD.command(stack, "web"),
        )
        assertNull(ComposeAction.REBUILD.command(stack, "nope"), "the service must exist in the stack")
        assertNull(ComposeAction.PULL.command(stack, "web"), "only rebuild can target one service")
        assertNull(ComposeAction.UP.command(stack.copy(workingDir = "relative/dir")))
        assertNull(ComposeAction.UP.command(stack.copy(name = "Bad Name")))
        assertNull(ComposeAction.UP.command(stack.copy(isStandalone = true)))
        assertNull(ComposeAction.REBUILD.command(stack, "web; reboot"))
    }

    @Test fun stacksWithDisagreeingLayoutsGetNoComposeCommand() {
        fun container(id: String, dir: String) = DockerContainer(
            id = id, name = id, image = "i", state = "running", health = "none", status = "Up", ports = emptyList(),
            project = "p", service = id, workingDir = dir, configFile = "$dir/compose.yaml", configFiles = listOf("$dir/compose.yaml"),
        )
        val stack = DockerSnapshot(listOf(container("aaaaaaaaaaaa", "/srv/a"), container("bbbbbbbbbbbb", "/srv/b"))).stacks.single()
        assertNull(stack.workingDir)
        assertNull(ComposeAction.UP.command(stack))
    }
}

class LogBufferTests {
    @Test fun joinsChunksSplitMidLineAndNormalisesCRLF() {
        val b = LogBuffer()
        b.append("first line\r\nsecond ")
        assertEquals(listOf("first line"), b.lines)
        b.append("line\r\nthird")
        assertEquals(listOf("first line", "second line"), b.lines)
        assertEquals("first line\nsecond line\nthird", b.text, "unfinished last line is still shown")
        b.append(" part\r\n")
        assertEquals("third part", b.lines.last())
    }

    @Test fun dropsSSHClosedNoticeAndCapsLines() {
        val b = LogBuffer(maxLines = 3)
        b.append("a\nb\nc\nd\nConnection to hetzner closed.\r\n")
        assertEquals(listOf("b", "c", "d"), b.lines)
    }

    @Test fun totalAppendedKeepsCountingAfterTheBufferIsFull() {
        val b = LogBuffer(maxLines = 3)
        b.append("a\nb\nc\nd\ne\n")
        assertEquals(listOf("c", "d", "e"), b.lines)
        assertEquals(5, b.totalAppended)
        b.append("f\npartial")
        assertEquals(6, b.totalAppended, "an unfinished line is not counted until it ends")
        b.append("ial\nConnection to host closed.\n")
        assertEquals(7, b.totalAppended, "the finished partial line counts; ssh's own closing notice does not")
    }
}

class LogLineParserTests {
    @Test fun levels() {
        val p = LogLineParser
        assertEquals(LogLevel.ERROR, p.level("""2026/10/10 00:20:05.642147 [error] dnsproxy: exchange failed err="unexpected EOF""""))
        assertEquals(LogLevel.INFO, p.level("""{"level":"info","time":"2026-10-09T20:39:12Z","msg":"removed 13 streams"}"""))
        assertEquals(LogLevel.WARN, p.level("""time=2026-10-09T21:00:04Z level=WARN source=x msg="slow""""))
        assertEquals(LogLevel.WARN, p.level("17:50:41 WARN Retrying indexer (2/3)"))
        assertEquals(LogLevel.ERROR, p.level("17:51:12 ERROR Database is locked"))
        assertEquals(LogLevel.DEBUG, p.level("level: debug starting"))
        assertEquals(LogLevel.DEBUG, p.level("[trace] noisy"))
        assertEquals(LogLevel.ERROR, p.level("[FATAL] gone"))
    }

    @Test fun proseIsNotGuessed() {
        val p = LogLineParser
        assertNull(p.level("no error occurred, nothing to warn about"))
        assertNull(p.level("GET /api/info 200"))
        assertNull(p.level(""))
        assertEquals(LogLevel.INFO, p.level("""{"level":"info","msg":"an error was handled"}"""), "explicit level beats words in the message")
    }

    @Test fun timestampLength() {
        assertEquals(24, LogLineParser.timestampLength("2026-10-09T20:39:12.454Z INFO x"))
        assertEquals(26, LogLineParser.timestampLength("2026/10/10 00:20:05.642147 [error]"))
        assertEquals(8, LogLineParser.timestampLength("17:51:12 ERROR Database"))
        assertEquals(0, LogLineParser.timestampLength("no timestamp here"))
        assertEquals(0, LogLineParser.timestampLength("level=info time=2026-10-09T20:39:12Z"), "only a leading timestamp")
    }
}

class ModelsAndSessionTests {
    @Test fun serverRoundTripsThroughJSON() {
        val server = Server("1", "vps", "vps.example.com")
        assertEquals(server, Spec.json.decodeFromString<Server>(Spec.json.encodeToString(server)))
    }

    @Test fun sshDestination() {
        assertEquals("h", Server("1", "a", "h").sshDestination)
        assertEquals("root@h", Server("1", "a", "h", user = "root").sshDestination)
        assertEquals("h", Server("1", "a", "h", user = "").sshDestination, "empty user is ignored")
    }

    @Test fun oldServerJSONWithoutUserOrPortStillDecodes() {
        val s = Spec.json.decodeFromString<Server>("""{"id":"1","name":"vps","host":"vps.example.com"}""")
        assertNull(s.user)
        assertNull(s.port)
    }

    @Test fun cachedOverviewShowsAsStaleUntilFirstPollThenPersists() = runTest {
        val text = Spec.out("overview", "ubuntu-24.04")
        val cached = OverviewParser.parse(text)
        var saved: Overview? = null
        val session = ServerSession(FakeTransport(listOf(ok(text))), cached = ServerSession.Cached(cached, 1), onSnapshot = { saved = it })
        assertTrue(session.state.value.isStale)
        assertEquals(cached, session.state.value.overview, "instant paint from the cache")
        session.refresh()
        assertFalse(session.state.value.isStale)
        assertNotNull(saved, "a successful poll is persisted")
    }

    @Test fun failedFirstPollKeepsStaleCacheVisible() = runTest {
        val cached = OverviewParser.parse(Spec.out("overview", "ubuntu-24.04"))
        val session = ServerSession(FakeTransport(listOf(ok("", "timeout", 255))), cached = ServerSession.Cached(cached, 1))
        session.refresh()
        assertTrue(session.state.value.isStale)
        assertEquals("timeout", session.state.value.error)
        assertNotNull(session.state.value.overview)
    }

    @Test fun overviewCommandComesFromTheSpecAndTwoPollsGiveCpuUse() = runTest {
        assertTrue(ServerSession.overviewCommand.startsWith("echo '##hostname'; hostname;"))
        val text = Spec.out("overview", "ubuntu-24.04")
        // Same server a moment later: 1000 more busy ticks, nothing idle, so the interval was 100% busy.
        val later = text.lines().joinToString("\n") { line ->
            if (!line.startsWith("cpu ")) line
            else {
                val f = line.split(' ').filter { it.isNotEmpty() }
                "cpu  " + (listOf((f[1].toLong() + 1000).toString()) + f.drop(2)).joinToString(" ")
            }
        }
        val session = ServerSession(FakeTransport(listOf(ok(text), ok(later))))
        session.refresh()
        assertNull(session.state.value.cpuPercent, "CPU needs two readings")
        session.refresh()
        assertEquals(100.0, session.state.value.cpuPercent)
    }
}
