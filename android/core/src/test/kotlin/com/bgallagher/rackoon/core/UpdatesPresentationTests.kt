package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UpdatesPresentationTests {
    private fun pkg(name: String, security: Boolean = false) = PendingUpdate(name, if (security) "noble-security" else "noble-updates", "2", "1", "amd64", security)
    private fun snap(vararg p: PendingUpdate, refreshed: Long? = null) = UpdatesSnapshot(p.toList(), emptyList(), refreshed, false)

    @Test fun subtitleCountsUpdatesAndSecurity() {
        assertEquals("Everything is up to date", UpdatesPresentation.subtitle(snap()))
        assertEquals("1 update available", UpdatesPresentation.subtitle(snap(pkg("a"))))
        assertEquals("3 updates available, 1 security", UpdatesPresentation.subtitle(snap(pkg("a"), pkg("b"), pkg("c", true))))
    }

    @Test fun relativeAgeUsesTheLargestUnit() {
        assertEquals("just now", UpdatesPresentation.relativeAge(30))
        assertEquals("1 minute ago", UpdatesPresentation.relativeAge(60))
        assertEquals("5 hours ago", UpdatesPresentation.relativeAge(5 * 3600L + 59))
        assertEquals("3 days ago", UpdatesPresentation.relativeAge(3 * 86_400L))
        assertEquals("2 months ago", UpdatesPresentation.relativeAge(61 * 86_400L))
        assertEquals("just now", UpdatesPresentation.relativeAge(-5))
    }

    @Test fun stalenessOnlyAfterThreeDays() {
        val now = 10_000_000L
        assertNull(UpdatesPresentation.staleness(snap(refreshed = now - 3 * 86_400), now))
        assertEquals("Package lists were refreshed 4 days ago. Refresh them to see newer updates.", UpdatesPresentation.staleness(snap(refreshed = now - 4 * 86_400), now))
        assertNull(UpdatesPresentation.staleness(snap(), now))
        assertEquals("unknown", UpdatesPresentation.refreshedText(snap(), now))
        assertEquals("2 hours ago", UpdatesPresentation.refreshedText(snap(refreshed = now - 7200), now))
    }

    @Test fun securityComesFirstThenName() {
        val sorted = UpdatesPresentation.sorted(listOf(pkg("zlib"), pkg("curl", true), pkg("bash"), pkg("openssl", true))).map { it.name }
        assertEquals(listOf("curl", "openssl", "bash", "zlib"), sorted)
        assertEquals(listOf("curl", "openssl"), UpdatesPresentation.securityNames(listOf(pkg("zlib"), pkg("openssl", true), pkg("curl", true))))
    }

    @Test fun installSecurityHasAReasonWhenOff() {
        val some = listOf(pkg("a", true), pkg("b"))
        assertTrue(UpdatesPresentation.canInstallSecurity(some))
        assertNull(UpdatesPresentation.installSecurityHint(some, readOnly = false))
        assertEquals("Read-only mode is on", UpdatesPresentation.installSecurityHint(some, readOnly = true))
        assertEquals("No security updates", UpdatesPresentation.installSecurityHint(listOf(pkg("b")), false))
        val many = (1..AptAction.MAX_PACKAGES + 1).map { pkg("pkg$it", true) }
        assertFalse(UpdatesPresentation.canInstallSecurity(many))
        assertEquals("Too many to list one by one; use Install All", UpdatesPresentation.installSecurityHint(many, false))
    }

    @Test fun promptsSayWhatWillHappen() {
        assertEquals("Refresh package lists?", UpdatesPresentation.prompt(AptAction.Refresh, 5, 2).title)
        assertEquals("Install all 5 updates?", UpdatesPresentation.prompt(AptAction.UpgradeAll, 5, 2).title)
        val p = UpdatesPresentation.prompt(AptAction.Upgrade(listOf("a", "b", "c", "d", "e", "f", "g", "h")), 9, 8)
        assertEquals("Install 8 security updates?", p.title)
        assertEquals("Only these packages are upgraded: a, b, c, d, e, f and 2 more.", p.message)
        assertEquals("apt-get install --only-upgrade (8 packages)", p.outputTitle)
        assertEquals("Install 1 security update?", UpdatesPresentation.prompt(AptAction.Upgrade(listOf("a")), 1, 1).title)
    }
}
