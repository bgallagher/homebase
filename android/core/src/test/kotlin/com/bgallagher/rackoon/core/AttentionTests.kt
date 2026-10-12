package com.bgallagher.rackoon.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals

class AttentionTests {
    private fun base() = OverviewParser.parse(Spec.out("overview", "ubuntu-24.04"))

    @Test fun healthyServerNeedsNothing() {
        assertEquals(emptyList(), Attention.evaluate(base().copy(disks = emptyList(), unhealthyContainers = emptyList(), securityUpdates = 0, rebootRequired = false)))
    }

    @Test fun rulesMatchTheSpec() {
        val rules = ((Spec.parse("attention-rules.json") as JsonObject)["rules"] as JsonArray).map { (it as JsonObject)["id"]!!.jsonPrimitive.content }
        assertEquals(listOf("disk_high", "container_unhealthy", "security_updates", "reboot_required"), rules)
        val o = base().copy(
            disks = listOf(Overview.Disk("/dev/sda1", "/", 100, 90, 90), Overview.Disk("/dev/sdb1", "/data", 100, 97, 97), Overview.Disk("/dev/sdc", "/ok", 100, 85, 85)),
            unhealthyContainers = listOf("web"), securityUpdates = 1, rebootRequired = true,
        )
        val items = Attention.evaluate(o)
        assertEquals(
            listOf("disk_high:/", "disk_high:/data", "container_unhealthy:web", "security_updates", "reboot_required"),
            items.map { it.id },
        )
        assertEquals(AttentionItem.Severity.WARNING, items[0].severity)
        assertEquals(AttentionItem.Severity.CRITICAL, items[1].severity, "95 and above is critical")
        assertEquals("/data is 97% full.", items[1].message)
        assertEquals("1 security update is available.", items[3].message)
        assertEquals("updates", items[4].fix)
    }

    @Test fun pluralSecurityMessage() {
        assertEquals("3 security updates are available.", Attention.evaluate(base().copy(disks = emptyList(), securityUpdates = 3)).single().message)
    }
}
