package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AptActionTests {
    private fun entry(id: String): JsonObject {
        val commands = (Spec.parse("commands.json") as JsonObject)["commands"] as JsonArray
        return commands.map { it as JsonObject }.first { it["id"]!!.jsonPrimitive.content == id }
    }

    @Test fun commandsMatchSpec() {
        for (id in listOf("apt_refresh", "apt_upgrade", "apt_upgrade_packages")) assertEquals("action", entry(id)["kind"]!!.jsonPrimitive.content)
        assertEquals(entry("apt_refresh")["script"]!!.jsonPrimitive.content, AptAction.Refresh.command)
        assertEquals(entry("apt_upgrade")["script"]!!.jsonPrimitive.content, AptAction.UpgradeAll.command)
        assertEquals(
            entry("apt_upgrade_packages")["script"]!!.jsonPrimitive.content.replace("{packages}", "pkg-a pkg-b"),
            AptAction.Upgrade(listOf("pkg-a", "pkg-b")).command,
        )
    }

    @Test fun upgradeListsPackagesAndNeverRemoves() {
        val c = assertNotNull(AptAction.Upgrade(listOf("openssl", "libssl3t64", "g++-13")).command)
        assertTrue(c.endsWith("install --only-upgrade -y -o Dpkg::Options::=--force-confold openssl libssl3t64 g++-13"))
        for (action in listOf(AptAction.Refresh, AptAction.UpgradeAll, AptAction.Upgrade(listOf("openssl")))) {
            val command = assertNotNull(action.command)
            assertFalse(command.contains("dist-upgrade") || command.contains("remove") || command.contains("purge") || command.contains("autoremove"))
            assertTrue(command.contains("DEBIAN_FRONTEND=noninteractive"), "must never prompt")
            assertTrue(command.contains("sudo -n"), "must never ask for a password")
        }
    }

    @Test fun duplicatesAreRemovedAndTheListIsCapped() {
        val c = assertNotNull(AptAction.Upgrade(listOf("openssl", "curl", "openssl")).command)
        assertTrue(c.endsWith(" openssl curl"))
        val many = (0 until AptAction.MAX_PACKAGES).map { "pkg-$it" }
        assertNotNull(AptAction.Upgrade(many).command)
        assertNull(AptAction.Upgrade(many + "one-more").command)
        assertTrue(assertNotNull(AptAction.Upgrade(many).command).toByteArray().size < 8_000)
        assertTrue(assertNotNull(AptAction.Refresh.command).contains("LC_ALL=C"))
    }

    @Test fun packageNamesAreValidated() {
        for (bad in listOf("", "a", "Openssl", "-o", "foo;reboot", "foo bar", "$(id)", "a\nb", "foo|bar", "a`b`", "ünï")) {
            assertNull(AptAction.Upgrade(listOf(bad)).command, bad)
        }
        assertNull(AptAction.Upgrade(emptyList()).command)
        assertNull(AptAction.Upgrade(listOf("openssl", "x;y")).command, "one bad name rejects the whole list")
        assertNotNull(AptAction.Upgrade(listOf("libstdc++6", "python3.12", "0ad")).command)
    }

    /** The root/sudo prefix runs through a real /bin/sh with apt-get replaced by a stub on PATH. */
    @Test fun realShellPicksSudoOnlyWhenNotRoot() {
        val dir = Files.createTempDirectory("rk-apt").toFile()
        try {
            fun stub(name: String, body: String) = File(dir, name).apply { writeText("#!/bin/sh\n$body\n"); setExecutable(true) }
            stub("apt-get", "echo \"apt-get \$*\"")
            stub("sudo", "echo \"sudo \$*\"; shift; shift; \"\$@\"") // sudo -n env ... apt-get ...
            val p = ProcessBuilder("/bin/sh", "-c", assertNotNull(AptAction.Refresh.command)).redirectErrorStream(true)
            p.environment()["PATH"] = dir.path + ":/usr/bin:/bin"
            val proc = p.start()
            val out = proc.inputStream.readBytes().toString(Charsets.UTF_8)
            proc.waitFor(10, TimeUnit.SECONDS)
            val isRoot = ProcessBuilder("id", "-u").start().inputStream.readBytes().toString(Charsets.UTF_8).trim() == "0"
            if (isRoot) assertEquals("apt-get update\n", out)
            else assertTrue(out.contains("sudo -n env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get update"), out)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun explainsSudoAndLockFailures() {
        assertTrue(AptAction.explain(stderr = "sudo: a password is required", exitCode = 1).contains("passwordless sudo"))
        assertTrue(AptAction.explain(stderr = "E: Could not get lock /var/lib/dpkg/lock-frontend", exitCode = 100).contains("lock"))
        assertEquals("b\nc\nd", AptAction.explain(stderr = "a\nb\nc\nd", exitCode = 100))
        // sudo's text is localised but always starts with "sudo:"; apt's real errors can arrive on stdout.
        assertTrue(AptAction.explain(stderr = "sudo: un mot de passe est nécessaire", exitCode = 1).contains("passwordless sudo"))
        assertTrue(AptAction.explain(stdout = "E: dpkg was interrupted, you must manually run 'dpkg --configure -a'", stderr = "", exitCode = 100).contains("dpkg --configure -a"))
        assertEquals(
            "E: Unable to correct problems, you have held broken packages.",
            AptAction.explain(stdout = "noise\nE: Unable to correct problems, you have held broken packages.", stderr = "", exitCode = 100),
        )
        assertEquals("apt-get failed (exit 7)", AptAction.explain(stderr = "", exitCode = 7))
    }
}

class UpdatesSessionActionTests {
    private fun read(name: String) = Spec.out("updates", name)

    @Test fun runsConfirmedActionThenRereadsTheList() = runTest {
        val transport = FakeTransport(listOf(ok("Reading package lists...\nDone\n"), ok(read("ubuntu-24.04-current"))))
        val session = UpdatesSession(transport)
        val action = AptAction.Upgrade(listOf("openssl"))
        session.perform(action, session.confirm(action))
        assertEquals(action.command, transport.commands.first())
        assertEquals(2, transport.commands.size, "action, then the update list")
        val state = session.state.value
        assertFalse(state.isWorking)
        assertNull(state.actionError)
        assertEquals("Reading package lists...\nDone", state.actionOutput)
        assertEquals(0, state.snapshot?.packages?.size)
    }

    @Test fun needsConfirmationAndReadOnlyBlocks() = runTest {
        val transport = FakeTransport()
        val session = UpdatesSession(transport)
        session.perform(AptAction.UpgradeAll, null)
        assertTrue(transport.commands.isEmpty())
        assertEquals(PolicyError.NotConfirmed.message, session.state.value.actionError)

        val readOnly = UpdatesSession(transport, ActionPolicy(readOnly = true))
        assertFailsWith<PolicyError.ReadOnly> { readOnly.confirm(AptAction.Refresh) }
        readOnly.perform(AptAction.Refresh, null)
        assertTrue(transport.commands.isEmpty())
        assertEquals(PolicyError.ReadOnly.message, readOnly.state.value.actionError)
    }

    @Test fun sudoFailureIsExplainedAndListStillRefreshes() = runTest {
        val transport = FakeTransport(listOf(ok("", "sudo: a password is required", 1), ok(read("synthetic-security-pending"))))
        val session = UpdatesSession(transport)
        session.perform(AptAction.Refresh, session.confirm(AptAction.Refresh))
        val state = session.state.value
        assertTrue(state.actionError?.contains("passwordless sudo") == true)
        assertEquals(3, state.snapshot?.securityCount)
    }

    @Test fun staleOutputIsClearedWhenALaterActionIsRefused() = runTest {
        val transport = FakeTransport(listOf(ok("done\n"), ok(read("ubuntu-24.04-current"))))
        val session = UpdatesSession(transport)
        session.perform(AptAction.Refresh, session.confirm(AptAction.Refresh))
        assertEquals("done", session.state.value.actionOutput)
        session.perform(AptAction.UpgradeAll, null)
        assertNull(session.state.value.actionOutput, "no 'done' beside a new error")
        assertNotNull(session.state.value.actionError)
    }

    @Test fun invalidPackageNameNeverRuns() = runTest {
        val transport = FakeTransport()
        val session = UpdatesSession(transport)
        assertFailsWith<PolicyError.InvalidTarget> { session.confirm(AptAction.Upgrade(listOf("x; reboot"))) }
        session.perform(AptAction.Upgrade(listOf("x; reboot")), null)
        assertTrue(transport.commands.isEmpty())
    }
}
