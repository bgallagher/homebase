package com.bgallagher.rackoon.core

/** How an attention item is shown on the Overview: one short line, and whether it is red (failing) or amber (needs attention). */
object AttentionPresentation {
    /** Failing things are red. An unhealthy container is red here even though the shared rules call it a warning. */
    fun isRed(item: AttentionItem): Boolean = item.severity == AttentionItem.Severity.CRITICAL || item.id.startsWith("container_unhealthy")

    /** "cloudflared is unhealthy", "2 security updates", "Reboot required", "/ is 91% full": no filler words, no full stop. */
    fun shortMessage(item: AttentionItem): String = when {
        item.id == "reboot_required" -> "Reboot required"
        item.id == "security_updates" -> item.message.removeSuffix(".").replace(" are available", "").replace(" is available", "")
        else -> item.message.removeSuffix(".")
    }

    /** Red items first, then amber; each group keeps its order. */
    fun sorted(items: List<AttentionItem>): List<AttentionItem> = items.sortedBy { if (isRed(it)) 0 else 1 }
}
