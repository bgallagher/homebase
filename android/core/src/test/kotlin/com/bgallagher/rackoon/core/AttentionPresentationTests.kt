package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AttentionPresentationTests {
    private fun item(id: String, message: String, severity: AttentionItem.Severity = AttentionItem.Severity.WARNING) = AttentionItem(id, severity, message, "docker")

    @Test fun messagesLoseTheirFiller() {
        assertEquals("cloudflared is unhealthy", AttentionPresentation.shortMessage(item("container_unhealthy:cloudflared", "cloudflared is unhealthy.")))
        assertEquals("2 security updates", AttentionPresentation.shortMessage(item("security_updates", "2 security updates are available.")))
        assertEquals("1 security update", AttentionPresentation.shortMessage(item("security_updates", "1 security update is available.")))
        assertEquals("Reboot required", AttentionPresentation.shortMessage(item("reboot_required", "A reboot is required to finish applying updates.")))
        assertEquals("/ is 91% full", AttentionPresentation.shortMessage(item("disk_high:/", "/ is 91% full.", AttentionItem.Severity.WARNING)))
    }

    @Test fun failingThingsAreRedAndSortFirst() {
        val unhealthy = item("container_unhealthy:db", "db is unhealthy.")
        val reboot = item("reboot_required", "A reboot is required to finish applying updates.")
        val disk = item("disk_high:/", "/ is 97% full.", AttentionItem.Severity.CRITICAL)
        assertTrue(AttentionPresentation.isRed(unhealthy))
        assertTrue(AttentionPresentation.isRed(disk))
        assertFalse(AttentionPresentation.isRed(reboot))
        assertEquals(listOf(unhealthy, disk, reboot), AttentionPresentation.sorted(listOf(reboot, unhealthy, disk)))
    }
}
