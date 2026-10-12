package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CommandLibraryTests {
    @Test fun entriesAreWellFormed() {
        val all = CommandLibrary.all
        assertEquals(38, all.size)
        assertEquals(all.size, all.map { it.id }.toSet().size, "ids are unique")
        val placeholder = Regex("\\{([a-z]+)}")
        for (c in all) {
            assertTrue(c.group in CommandLibrary.groups, c.id)
            assertFalse(c.title.isEmpty() || c.summary.isEmpty() || c.script.isEmpty(), c.id)
            // Every {placeholder} has a parameter and every parameter is used.
            val used = placeholder.findAll(c.script).map { it.groupValues[1] }.toSet() - setOf("Names", "Status", "Image")
            assertEquals(used, c.params.map { it.id }.toSet(), c.id)
            if (c.root) assertTrue(c.script.contains("\$S"), "${c.id} is marked root but never uses \$S")
            if (c.isMutating) {
                assertEquals("Maintenance", c.group, c.id)
                assertNotNull(c.preview, "${c.id} needs a dry-run preview")
                assertFalse(c.interactive, c.id)
            } else {
                assertNull(c.preview, "${c.id}: read entries have nothing to preview")
                assertNull(c.warning, c.id)
            }
        }
        assertFalse(CommandLibrary.commands("Maintenance").any { !it.isMutating }, "Maintenance is only for changes")
        for (group in CommandLibrary.groups) assertTrue(CommandLibrary.commands(group).isNotEmpty(), group)
    }

    @Test fun rootNeedsAndParameterGuards() {
        val ports = CommandLibrary.all.first { it.id == "listening_ports" }
        val path = """PATH="${'$'}PATH:/usr/local/sbin:/usr/sbin:/sbin"; export PATH; """
        assertEquals(path + """if [ "${'$'}(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; ${'$'}S ss -tulpn""", ports.fullScript())
        val docker = CommandLibrary.all.first { it.id == "docker_disk" }
        assertEquals(path + "command -v docker >/dev/null 2>&1 || { echo 'docker is not installed on this server.'; exit 0; }; docker system df", docker.fullScript())

        val logs = CommandLibrary.all.first { it.id == "container_logs" }
        assertTrue(assertNotNull(logs.fullScript(params = mapOf("container" to "my-app_1"))).endsWith("docker logs --tail 200 'my-app_1' 2>&1"))
        for (bad in listOf("", "a b", "x; reboot", "$(id)", "-rf", "a/b", "web\nlogs")) {
            assertNull(logs.fullScript(params = mapOf("container" to bad)), bad)
        }
        assertNull(logs.fullScript(), "a missing parameter is refused")
        val cert = CommandLibrary.all.first { it.id == "cert_expiry" }
        assertNotNull(cert.fullScript(params = mapOf("host" to "app.example.com")))
        for (bad in listOf("", "-x.com", "a..b", "a b.com", "x.com;ls", "x.com/path", ".x.com", "x.com.")) assertNull(cert.fullScript(params = mapOf("host" to bad)), bad)
    }

    private fun runSh(script: String, path: String? = null): Pair<Int, String> {
        val p = ProcessBuilder("/bin/sh", "-c", script).redirectErrorStream(true)
        if (path != null) p.environment()["PATH"] = path
        val proc = p.start()
        val out = proc.inputStream.readBytes().toString(Charsets.UTF_8)
        proc.waitFor(10, TimeUnit.SECONDS)
        return proc.exitValue() to out
    }

    /** Runs the guard prefix under a real /bin/sh: a missing program prints a sentence and exits 0 instead of failing. */
    @Test fun missingProgramGuardUnderARealShell() {
        val c = LibraryCommand("x", "x", "Disk", "x", "echo SHOULD-NOT-RUN", needs = "rackoon-no-such-program")
        val (code, out) = runSh(assertNotNull(c.fullScript()))
        assertEquals(0, code)
        assertEquals("rackoon-no-such-program is not installed on this server.\n", out)
    }

    /** A program that lives only in an sbin directory is found even when the ssh user's PATH has none. */
    @Test fun programsInSbinAreFoundWithAMinimalPath() {
        val sbin = listOf("/usr/sbin", "/sbin").firstOrNull { d -> File(d).listFiles()?.any { it.isFile && it.canExecute() && !File("/usr/bin/${it.name}").exists() && !File("/bin/${it.name}").exists() } == true } ?: return
        val program = File(sbin).listFiles()!!.first { it.isFile && it.canExecute() && !File("/usr/bin/${it.name}").exists() && !File("/bin/${it.name}").exists() }.name
        val c = LibraryCommand("x", "x", "Disk", "x", "echo RAN", needs = program)
        assertEquals("RAN\n", runSh(assertNotNull(c.fullScript()), path = "/nonexistent").second)
    }

    @Test fun readRunsWithoutConfirmationAndMutationsNeedOne() = runTest {
        val transport = FakeTransport()
        val session = CommandLibrarySession(transport, ActionPolicy())
        val read = assertNotNull(session.intent(CommandLibrary.all.first { it.id == "load" }))
        assertEquals(Risk.READ, read.risk)
        assertNotNull(session.run(read, null, 80, 24) {}, "a read runs straight away")
        assertEquals(1, transport.streamedCommands.size)

        val prune = CommandLibrary.all.first { it.id == "docker_prune" }
        val intent = assertNotNull(session.intent(prune, preview = "Stopped container: old"))
        assertEquals(Risk.MUTATE, intent.risk)
        assertNull(session.run(intent, null, 80, 24) {}, "a change without a confirmation does not run")
        assertEquals(1, transport.streamedCommands.size)
        // The confirmation is for the exact intent, preview included.
        val other = assertNotNull(session.intent(prune, preview = "something else"))
        assertNull(session.run(intent, session.confirm(other), 80, 24) {})
        assertNotNull(session.run(intent, session.confirm(intent), 80, 24) {})
        assertEquals(2, transport.streamedCommands.size)
    }

    @Test fun readOnlyModeBlocksMutationsButNotReads() = runTest {
        val session = CommandLibrarySession(FakeTransport(), ActionPolicy(readOnly = true))
        val prune = assertNotNull(session.intent(CommandLibrary.all.first { it.id == "docker_prune" }))
        assertFailsWith<PolicyError.ReadOnly> { session.confirm(prune) }
        val read = assertNotNull(session.intent(CommandLibrary.all.first { it.id == "memory" }))
        assertNotNull(session.run(read, null, 80, 24) {}, "reading is always allowed")
    }

    @Test fun customCommandsAlwaysNeedConfirmation() {
        val session = CommandLibrarySession(FakeTransport(), ActionPolicy())
        val intent = assertNotNull(session.customIntent("  uname -a \n"))
        assertEquals("uname -a", intent.command)
        assertEquals(Risk.MUTATE, intent.risk)
        for (bad in listOf("", "   ", "x".repeat(4001), "a\u0000b")) assertNull(session.customIntent(bad))
    }

    @Test fun previewRunsTheDryRunAsARead() = runTest {
        val transport = FakeTransport(listOf(ok("Stopped container: old\n")))
        val session = CommandLibrarySession(transport, ActionPolicy())
        val prune = CommandLibrary.all.first { it.id == "docker_prune" }
        assertEquals("Stopped container: old", session.preview(prune))
        val sent = transport.commands.first()
        assertTrue(sent.contains("docker images -f dangling=true"))
        for (what in listOf("Stopped container", "Unused network", "Dangling image", "docker system df")) assertTrue(sent.contains(what), "the prune preview lists: $what")
        assertFalse(sent.contains("prune"), "the preview never contains the real command")
    }
}

class RebootTests {
    private fun overview(name: String) = OverviewParser.parse(Spec.out("overview", name))
    private val down = ok("", "ssh: connect to host: Connection refused", 255)

    @Test fun systemFieldsAndModelName() {
        val o = overview("ubuntu-24.04")
        assertEquals("Hetzner vServer", o.modelName)
        assertEquals(32, o.machineID.length)
        assertEquals("6.8.0-146-generic", o.kernel)
        assertEquals(1791615000L, o.serverTime)
        assertEquals("UTC", o.timeZoneName)
    }

    @Test fun missingDMIAndANonUTCZone() {
        val o = overview("synthetic-no-dmi-offset-zone")
        assertEquals("", o.modelName, "no vendor or product reported")
        assertEquals(-(5 * 3600 + 30 * 60), o.utcOffsetSeconds)
        assertEquals("IST", o.timeZoneName)
    }

    @Test fun oldOutputWithoutASystemSectionStillParses() {
        var text = Spec.out("overview", "ubuntu-24.04")
        val a = text.indexOf("##system\n")
        val b = text.indexOf("##reboot\n")
        text = text.removeRange(a, b)
        val o = OverviewParser.parse(text)
        assertEquals("", o.bootID)
        assertEquals(0L, o.serverTime)
        assertFalse(o.hostname.isEmpty())
    }

    @Test fun rebootNeedsConfirmationAndHonoursReadOnly() = runTest {
        val t = FakeTransport()
        assertFailsWith<PolicyError.NotConfirmed> { RebootSession(t).reboot(null) }
        val ro = RebootSession(t, ActionPolicy(readOnly = true))
        assertFailsWith<PolicyError.ReadOnly> { ro.confirm() }
        assertTrue(t.commands.isEmpty(), "nothing was sent")
    }

    @Test fun readsTheBootIDThenSchedulesTheReboot() = runTest {
        val t = FakeTransport(listOf(ok("aaa-111\n"), ok("##rebooting\n")))
        val session = RebootSession(t)
        session.reboot(session.confirm())
        assertEquals(listOf(RebootSession.bootIDCommand, RebootSession.rebootCommand), t.commands)
    }

    @Test fun noSudoIsExplainedAndNothingIsWaitedFor() = runTest {
        val t = FakeTransport(listOf(ok("aaa\n"), ok("##no-sudo\n", exitCode = 5)))
        val session = RebootSession(t)
        assertFailsWith<RebootError.NoSudo> { session.reboot(session.confirm()) }
        assertEquals(RebootOutcome.TimedOut, session.waitForReturn(5_000, 0) {}, "no reboot was scheduled, so there is nothing to wait for")
    }

    private class Clock { var now = 1_000_000L; fun advance(ms: Long) { now += ms } }

    @Test fun waitsThroughDowntimeAndTheOldSystemUntilTheBootIDChanges() = runTest {
        val t = FakeTransport(listOf(ok("aaa\n"), ok("##rebooting\n"), ok("aaa\n"), down, down, ok("bbb\n")))
        val session = RebootSession(t)
        val clock = Clock()
        session.reboot(session.confirm()) { clock.now }
        val outcome = session.waitForReturn(600_000, 4_000, { clock.now }) { clock.advance(it) }
        val back = outcome as? RebootOutcome.Back ?: error("$outcome")
        assertTrue(back.elapsedMillis > 0)
        assertEquals(5, t.commands.count { it == RebootSession.bootIDCommand }, "1 before + 4 polls")
    }

    @Test fun timesOutIfTheServerNeverComesBack() = runTest {
        val t = FakeTransport(listOf(ok("aaa\n"), ok("##rebooting\n"), down))
        val session = RebootSession(t)
        val clock = Clock()
        session.reboot(session.confirm()) { clock.now }
        assertEquals(RebootOutcome.TimedOut, session.waitForReturn(60_000, 4_000, { clock.now }) { clock.advance(it) })
    }
}
