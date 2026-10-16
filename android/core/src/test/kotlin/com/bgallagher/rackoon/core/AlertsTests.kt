package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Mirrors AlertsTests.swift. Times are epoch milliseconds. */
class AlertsTests {
    private val t0 = 1_800_000_000_000L
    private fun later(minutes: Int): Long = t0 + minutes * 60_000L

    private val critical = AttentionItem.Severity.CRITICAL
    private val warning = AttentionItem.Severity.WARNING
    private val info = AttentionItem.Severity.INFO

    private fun disk(percent: Int, mount: String = "/") = AlertSignal(
        key = "disk_high:$mount", category = AlertCategory.DISK, severity = if (percent >= 95) critical else warning,
        title = "Disk almost full", detail = "$mount is $percent% full.", fix = AlertFix("docker"),
    )

    // The book

    @Test fun firstReadingIsABaselineThenNewAlertsNotify() {
        val book = AlertBook()
        val first = book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90)), t0)
        assertTrue(first.isEmpty(), "what is already wrong at the first look is listed, not notified")
        assertEquals(1, book.active().size)
        val second = book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90), disk(88, mount = "/data")), later(1))
        assertEquals(listOf("disk_high:/data"), second.map { it.key })
        assertEquals(2, book.active().size)
        // Still there: last seen moves, nothing new to say.
        assertTrue(book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90), disk(88, mount = "/data")), later(2)).isEmpty())
        assertEquals(later(2), book.active().first { it.key == "disk_high:/" }.lastSeen)
        assertEquals(t0, book.active().first { it.key == "disk_high:/" }.firstSeen)
    }

    @Test fun gettingWorseNotifiesAndClearsTheSeenMark() {
        val book = AlertBook()
        book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90)), t0)
        val id = AlertBook.id("a", AlertSource.OVERVIEW, "disk_high:/")
        book.acknowledge(id)
        assertEquals(0, book.unseenCount())
        val raised = book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(97)), later(1))
        assertEquals(listOf(critical), raised.map { it.severity })
        assertEquals(1, book.unseenCount())
        assertEquals(critical, book.worstUnseen())
    }

    @Test fun aReadingOnlyResolvesItsOwnSource() {
        val book = AlertBook()
        book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90)), t0)
        book.apply("a", "lab", AlertSource.SERVICES, listOf(AlertSignal("service_failed:x", AlertCategory.SERVICES, critical, "x failed")), t0)
        book.apply("a", "lab", AlertSource.SERVICES, emptyList(), later(5))
        assertEquals(listOf("disk_high:/"), book.active().map { it.key }, "the services reading resolved its alert, not the disk one")
        assertEquals(listOf("service_failed:x"), book.history().map { it.key })
        assertEquals(later(5), book.history().first().resolvedAt)
        // Another server's reading touches nothing here.
        book.apply("b", "nuc", AlertSource.OVERVIEW, emptyList(), later(6))
        assertEquals(1, book.active(server = "a").size)
    }

    @Test fun comingBackIsANewOccurrence() {
        val book = AlertBook()
        book.apply("a", "lab", AlertSource.OVERVIEW, emptyList(), t0)
        assertEquals(1, book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90)), later(1)).size)
        book.apply("a", "lab", AlertSource.OVERVIEW, emptyList(), later(2))
        val again = book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(91)), later(3))
        assertEquals(later(3), again.first().firstSeen)
        assertEquals(1, book.history().size)
        assertEquals(1, book.active().size)
    }

    @Test fun mutedAlertsAreNotCountedOrNotified() {
        val book = AlertBook()
        book.apply("a", "lab", AlertSource.OVERVIEW, emptyList(), t0)
        book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90)), later(1))
        val id = AlertBook.id("a", AlertSource.OVERVIEW, "disk_high:/")
        book.mute(id)
        assertEquals(0, book.unseenCount())
        assertTrue(book.active().isEmpty())
        assertEquals(listOf(id), book.mutedAlerts().map { it.id })
        assertTrue(book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(97)), later(2)).isEmpty(), "muted: not even when worse")
        book.mute(id, false)
        assertEquals(1, book.active().size)
    }

    @Test fun infoAlertsAreListedButNeverCountedOrNotified() {
        val book = AlertBook()
        book.apply("a", "lab", AlertSource.CONTAINERS, emptyList(), t0)
        val signal = AlertSignal("docker_needs_sudo", AlertCategory.CONTAINERS, info, "Containers not checked")
        assertTrue(book.apply("a", "lab", AlertSource.CONTAINERS, listOf(signal), later(1)).isEmpty())
        assertEquals(1, book.active().size)
        assertEquals(0, book.unseenCount())
    }

    @Test fun orderingAcknowledgeAllForgetAndHistoryLimits() {
        val book = AlertBook()
        book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90, mount = "/old")), t0)
        book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90, mount = "/old"), disk(96)), later(1))
        assertEquals(listOf("disk_high:/", "disk_high:/old"), book.active().map { it.key }, "critical first")
        book.acknowledgeAll(server = "a")
        assertEquals(0, book.unseenCount(server = "a"))
        book.mute(AlertBook.id("a", AlertSource.OVERVIEW, "disk_high:/"))
        assertTrue(book.forget("a"))
        assertTrue(book.alerts.isEmpty())
        assertTrue(book.muted.isEmpty())
        assertFalse(book.forget("a"))

        // Resolved alerts older than a week go; the history is capped.
        val long = AlertBook()
        long.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90)), t0)
        long.apply("a", "lab", AlertSource.OVERVIEW, emptyList(), later(1))
        assertEquals(1, long.history().size)
        long.apply("a", "lab", AlertSource.OVERVIEW, emptyList(), t0 + 8 * AlertBook.DAY_MILLIS)
        assertTrue(long.history().isEmpty())
        for (i in 0 until AlertBook.HISTORY_LIMIT + 20) {
            long.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90, mount = "/m$i")), later(i * 2))
            long.apply("a", "lab", AlertSource.OVERVIEW, emptyList(), later(i * 2 + 1))
        }
        assertEquals(AlertBook.HISTORY_LIMIT, long.history().size)
    }

    @Test fun bookRoundTripsThroughJSON() {
        val book = AlertBook()
        book.apply("a", "lab", AlertSource.OVERVIEW, listOf(disk(90)), t0)
        book.mute("a|overview|x")
        val copy = Json.decodeFromString<AlertBook>(Json.encodeToString(book))
        assertEquals(book, copy)
        assertEquals(book, book.copy())
    }

    // Rules

    @Test fun connectionRules() {
        assertTrue(AlertRules.connection(error = null, blocked = null).isEmpty())
        val down = AlertRules.connection(error = "ssh: connect to host 10.0.0.9 port 22: No route to host", blocked = null)
        assertEquals(listOf("not_answering"), down.map { it.key })
        assertEquals(critical, down.first().severity)
        assertEquals("login_refused", AlertRules.connection(error = "user@h: Permission denied (publickey).", blocked = null).first().key)
        assertEquals(critical, AlertRules.connection(error = null, blocked = "The host key changed since you trusted it.").first().severity)
        assertEquals(info, AlertRules.connection(error = null, blocked = "Waiting for you to trust its host key.").first().severity)
    }

    @Test fun serviceRulesOnlyWatchShownServices() {
        val s = ServicesParser.parse(Spec.out("services", "synthetic-root-failed"))
        val all = AlertRules.services(s) { it.visibleByDefault }
        assertEquals(
            setOf("service_failed:system/backup-sync.service", "service_crashing:system/cloudflared.service", "service_stopped:system/beszel-agent.service"),
            all.map { it.key }.toSet(),
        )
        assertEquals(warning, all.first { it.key.startsWith("service_stopped") }.severity)
        assertEquals(AlertFix("services", target = "system/backup-sync.service"), all.first { it.key.startsWith("service_failed") }.fix)
        assertEquals(2, AlertRules.services(s) { it.id != "system/backup-sync.service" && it.visibleByDefault }.size, "hidden ones don't alert")
    }

    private fun states(name: String): DockerStatesReading = DockerStatesParser.parse(Spec.out("docker_states", name))

    @Test fun containerRules() {
        val problems = AlertRules.containers(states("synthetic-problems"))
        assertEquals(listOf("container_down:immich_redis", "container_down:paperless-worker", "container_down:old-thing"), problems.map { it.key })
        assertEquals(listOf(critical, warning, critical), problems.map { it.severity })
        assertEquals(AlertFix("docker", target = "immich"), problems.first().fix)
        assertEquals(AlertFix("docker", target = "standalone/old-thing"), problems.last().fix)
        assertTrue(AlertRules.containers(states("unraid-healthy")).isEmpty())
        assertEquals(listOf(info), AlertRules.containers(states("permission-denied")).map { it.severity })
        assertTrue(AlertRules.containers(states("not-installed")).isEmpty())
    }

    @Test fun overviewRules() {
        val o = OverviewParser.parse(Spec.out("overview", "synthetic-security-updates"))
        val signals = AlertRules.overview(o)
        assertEquals(Attention.evaluate(o).map { it.id }, signals.map { it.key })
        assertTrue(signals.any { it.key == "security_updates" && it.category == AlertCategory.UPDATES })
    }

    @Test fun certificateRulesAndTargets() {
        val day = AlertBook.DAY_MILLIS
        val checks = listOf(
            CertificateCheck("https://a.example.com/", "a.example.com", expires = t0 - day, checkedAt = t0),
            CertificateCheck("https://b.example.com/", "b.example.com", expires = t0 + 3 * day, checkedAt = t0),
            CertificateCheck("https://c.example.com/", "c.example.com", expires = t0 + 14 * day, checkedAt = t0),
            CertificateCheck("https://d.example.com/", "d.example.com", expires = t0 + 60 * day, checkedAt = t0),
            CertificateCheck("https://e.example.com/", "e.example.com", expires = null, checkedAt = t0),
        )
        val signals = AlertRules.certificates(checks, now = t0)
        assertEquals(listOf("cert:a.example.com", "cert:b.example.com", "cert:c.example.com"), signals.map { it.key })
        assertEquals(listOf(critical, critical, warning), signals.map { it.severity })
        assertEquals("It expires in 14 days.", signals[2].detail)
        assertEquals(
            listOf("https://a.example.com/", "https://a.example.com:8443/"),
            CertificateCheck.targets(listOf("https://a.example.com/x", "https://A.example.com/y", "http://b.example.com", "https://a.example.com:8443/", "not a url")),
        )
    }

    // The container reader

    @Test fun dockerStatesGoldenFixtures() {
        val names = Spec.fixtures("docker_states")
        assertEquals(4, names.size)
        for (name in names) {
            val actual = Json.parseToJsonElement(Spec.json.encodeToString(DockerStatesParser.parse(Spec.out("docker_states", name))))
            assertJsonEquals(Spec.expected("docker_states", name), actual, "docker_states/$name")
        }
    }

    @Test fun dockerStatesDetails() {
        val r = states("synthetic-problems")
        assertEquals(8, r.containers.size)
        assertEquals(1, r.containers.first { it.name == "paperless-worker" }.exitCode)
        assertEquals(137, r.containers.first { it.name == "uptime-kuma" }.exitCode)
        assertNull(r.containers.first { it.name == "immich_server" }.exitCode)
        assertEquals("https://photos.example.com", r.containers.first().href)
        val real = states("unraid-healthy")
        assertTrue(real.containers.size > 40)
        assertNull(real.problem)
    }

    @Test fun problemRoundTripsThroughSwiftShapedJSON() {
        for (problem in listOf(DockerStatesReading.Problem.NotInstalled, DockerStatesReading.Problem.PermissionDenied, DockerStatesReading.Problem.Other("boom"))) {
            val reading = DockerStatesReading(emptyList(), problem)
            assertEquals(reading, Spec.json.decodeFromString<DockerStatesReading>(Spec.json.encodeToString(reading)))
        }
        assertEquals("""{"containers":[],"problem":{"other":{"_0":"boom"}}}""",
            Spec.json.encodeToString(DockerStatesReading(emptyList(), DockerStatesReading.Problem.Other("boom"))))
    }

    @Test fun commandComesFromTheSpec() {
        assertEquals(SpecCommands.script("docker_states"), DockerStatesSession.command)
        assertTrue(DockerStatesSession.command.startsWith("docker ps -a --no-trunc"))
    }

    @Test fun sessionReadsOrGivesUpQuietly() = runTest {
        val good = Spec.out("docker_states", "synthetic-problems")
        val reading = DockerStatesSession(FakeTransport(listOf(ok(good)))).read()
        assertEquals(8, reading?.containers?.size)
        assertNull(DockerStatesSession(FakeTransport(listOf(ok("", stderr = "Connection closed", exitCode = 255)))).read())
    }
}
