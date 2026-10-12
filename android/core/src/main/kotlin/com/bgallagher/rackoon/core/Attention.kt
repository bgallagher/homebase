package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable

/** Mirrors `AttentionItem` in spec/models.schema.json and the rules in spec/attention-rules.json. */
@Serializable
data class AttentionItem(
    val id: String,
    val severity: Severity,
    val message: String,
    /** Screen that helps fix it: "docker", "updates", "terminal". */
    val fix: String,
) {
    @Serializable
    enum class Severity {
        @kotlinx.serialization.SerialName("info") INFO,
        @kotlinx.serialization.SerialName("warning") WARNING,
        @kotlinx.serialization.SerialName("critical") CRITICAL,
    }
}

object Attention {
    const val DISK_THRESHOLD_PERCENT = 85

    /** Pure function over a snapshot, so it can run in the app, a relay or an agent. */
    fun evaluate(overview: Overview): List<AttentionItem> {
        val items = mutableListOf<AttentionItem>()
        for (disk in overview.disks.filter { it.usePercent > DISK_THRESHOLD_PERCENT }) {
            items += AttentionItem(
                id = "disk_high:${disk.mount}",
                severity = if (disk.usePercent >= 95) AttentionItem.Severity.CRITICAL else AttentionItem.Severity.WARNING,
                message = "${disk.mount} is ${disk.usePercent}% full.",
                fix = "docker",
            )
        }
        for (name in overview.unhealthyContainers) {
            items += AttentionItem("container_unhealthy:$name", AttentionItem.Severity.WARNING, "$name is unhealthy.", "docker")
        }
        if (overview.securityUpdates > 0) {
            val n = overview.securityUpdates
            items += AttentionItem(
                "security_updates", AttentionItem.Severity.WARNING,
                if (n == 1) "1 security update is available." else "$n security updates are available.", "updates",
            )
        }
        if (overview.rebootRequired) {
            items += AttentionItem("reboot_required", AttentionItem.Severity.WARNING, "A reboot is required to finish applying updates.", "updates")
        }
        return items
    }
}
