package com.bgallagher.rackoon.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class LogFollowerTests {
    private fun container(id: String, service: String) = DockerContainer(
        id = id, name = "media-$service-1", image = "img", state = "running", health = "none", status = "Up", ports = emptyList(), project = "media", service = service,
    )

    private val web = container("aaaaaaaaaaaa", "web")
    private val db = container("bbbbbbbbbbbb", "db")

    @Test fun `lines from several containers are merged and tagged`() = runTest {
        val t = FakeTransport()
        t.streamsByCommand[DockerSession.logsCommand(web.id)!!] = listOf("2026-10-12T07:15:02Z INFO a1\r\n", "2026-10-12T07:15:03Z ERROR a2\r\n")
        t.streamsByCommand[DockerSession.logsCommand(db.id)!!] = listOf("level=warn msg=slow\r\n")
        val f = LogFollower(t)
        f.follow(this, listOf(web, db))
        advanceUntilIdle()
        val s = f.state.value
        assertEquals(3, s.received)
        assertEquals(setOf("web", "db"), s.entries.map { it.source }.toSet())
        assertEquals(listOf(LogLevel.INFO, LogLevel.ERROR), s.entries.filter { it.source == "web" }.map { it.level })
        assertEquals(LogLevel.WARN, s.entries.single { it.source == "db" }.level)
        assertFalse(s.live, "the streams ended, so it is no longer live")
        assertEquals(listOf(web.id, db.id), s.containers.map { it.id })
    }

    @Test fun `lines split across chunks are joined and endings normalised`() = runTest {
        val t = FakeTransport()
        t.streamChunks = listOf("hello wor", "ld\r\nsecond ", "line\r\nthird (no newline yet)")
        val f = LogFollower(t)
        f.follow(this, listOf(web))
        advanceUntilIdle()
        assertEquals(listOf("hello world", "second line"), f.state.value.entries.map { it.line })
    }

    @Test fun `the buffer is capped but received keeps counting`() = runTest {
        val t = FakeTransport()
        t.streamChunks = listOf((1..50).joinToString("") { "line $it\r\n" })
        val f = LogFollower(t, maxEntries = 10)
        f.follow(this, listOf(web))
        advanceUntilIdle()
        assertEquals(10, f.state.value.entries.size)
        assertEquals(50, f.state.value.received)
        assertEquals("line 50", f.state.value.entries.last().line)
    }

    @Test fun `following the same containers again does nothing and different ones restart`() = runTest {
        val t = FakeTransport()
        t.streamChunks = listOf("one\r\n")
        val f = LogFollower(t)
        f.follow(this, listOf(web))
        advanceUntilIdle()
        f.follow(this, listOf(web))   // same ids, stream ended: it may restart; the point is that identical running follows are skipped
        advanceUntilIdle()
        f.follow(this, listOf(db))
        advanceUntilIdle()
        assertEquals(listOf(db.id), f.state.value.containers.map { it.id })
        assertEquals(listOf("db"), f.state.value.entries.map { it.source }.distinct())
    }

    @Test fun `stop clears everything`() = runTest {
        val t = FakeTransport()
        t.streamChunks = listOf("one\r\n")
        val f = LogFollower(t)
        f.follow(this, listOf(web))
        advanceUntilIdle()
        f.stop()
        assertEquals(LogsState(), f.state.value)
    }

    @Test fun `a stream error is reported`() = runTest {
        val t = object : SSHTransport {
            override suspend fun run(command: String, timeoutMillis: Long) = CommandResult("")
            override fun stream(command: String) = kotlinx.coroutines.flow.flow<String> { throw IllegalStateException("connection dropped") }
        }
        val f = LogFollower(t)
        f.follow(this, listOf(web))
        advanceUntilIdle()
        assertEquals("connection dropped", f.state.value.error)
    }

    @Test fun `containers with an unsafe id are not followed`() = runTest {
        val f = LogFollower(FakeTransport())
        f.follow(this, listOf(container("not-hex; rm -rf /", "x")))
        advanceUntilIdle()
        assertTrue(f.state.value.entries.isEmpty())
    }
}

class LogViewTests {
    private fun entries(): List<LogEntry> = listOf(
        LogEntry(0, "web", "2026-10-12T07:15:02Z INFO started"),
        LogEntry(1, "web", "2026-10-12T07:15:03Z ERROR boom: connection refused"),
        LogEntry(2, "db", "level=warn msg=\"slow query\""),
        LogEntry(3, "db", "plain line with the word error in prose"),
    )

    @Test fun `filters combine`() {
        val e = entries()
        assertEquals(4, LogView.filtered(e).size)
        assertEquals(listOf(0, 1), LogView.filtered(e, focus = "web").map { it.id })
        assertEquals(listOf(1), LogView.filtered(e, level = LogLevel.ERROR).map { it.id })
        assertEquals(listOf(3), LogView.filtered(e, search = "PROSE").map { it.id })
        assertEquals(emptyList(), LogView.filtered(e, focus = "db", level = LogLevel.ERROR))
        assertEquals(listOf(2), LogView.filtered(e, focus = "db", level = LogLevel.WARN, search = "slow").map { it.id })
    }

    @Test fun `prose is not a level and counts follow the focus`() {
        val counts = LogView.counts(entries())
        assertEquals(4, counts[null])
        assertEquals(1, counts[LogLevel.ERROR])
        assertEquals(1, counts[LogLevel.WARN])
        assertEquals(1, counts[LogLevel.INFO])
        val web = LogView.counts(entries(), focus = "web")
        assertEquals(2, web[null])
        assertNull(web[LogLevel.WARN])
    }

    @Test fun `copy text tags the container only when several are mixed`() {
        val e = entries().take(2)
        assertEquals("web | ${e[0].line}\nweb | ${e[1].line}", LogView.text(e, showSource = true))
        assertEquals("${e[0].line}\n${e[1].line}", LogView.text(e, showSource = false))
    }

    @Test fun `a row shows time level and message separately`() {
        assertEquals(LogParts("2026-10-12T07:15:02Z", LogLevel.INFO, "started"), entries()[0].parts)
        assertEquals(LogParts("2026-10-12T07:15:03Z", LogLevel.ERROR, "boom: connection refused"), entries()[1].parts)
        assertEquals(LogParts(null, LogLevel.WARN, "msg=\"slow query\""), entries()[2].parts)
        assertEquals(LogParts(null, null, "plain line with the word error in prose"), entries()[3].parts)
        // The level word stays when it is in the middle of the message.
        assertEquals("job ERROR handler ran", LogEntry(9, "x", "2026-10-12T07:15:03Z job ERROR handler ran").parts.message)
    }
}
