package com.bgallagher.rackoon.core

import java.net.URI

/**
 * Where a link works: [LOCAL] = no real domain (a bare name like "dockge", `.local`/`.lan`, a private IP), which only resolves
 * from inside your network or tailnet; [TAILSCALE] = a `*.ts.net` name or 100.64.0.0/10 address; [PUBLIC] = a normal domain.
 * Mirrors `LinkScope` in the Mac app.
 */
enum class LinkScope(val title: String, val hint: String) {
    LOCAL("Local", "Names and addresses that only work from inside your network"),
    TAILSCALE("Tailscale", "Only reachable on your tailnet"),
    PUBLIC("Public", "Reachable from anywhere");

    companion object {
        fun of(href: String): LinkScope {
            val host = try { URI(href).host?.lowercase() } catch (_: Exception) { null } ?: return PUBLIC
            if (host.endsWith(".ts.net")) return TAILSCALE
            val parts = host.split('.').mapNotNull { it.toIntOrNull() }
            if (parts.size == 4 && host.split('.').size == 4) {
                if (parts[0] == 100 && parts[1] in 64..127) return TAILSCALE
                val private = parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && parts[1] in 16..31)
                return if (private) LOCAL else PUBLIC
            }
            val localSuffixes = listOf(".local", ".lan", ".home", ".internal", ".home.arpa", ".localdomain")
            return if (!host.contains('.') || localSuffixes.any { host.endsWith(it) }) LOCAL else PUBLIC
        }
    }
}

/** A bookmark's address as a short label: the host, plus a port and a path when there is one ("app.example.com/tv"). */
fun Bookmark.shortAddress(): String {
    val uri = try { URI(href) } catch (_: Exception) { return href }
    val host = uri.host ?: return href
    val path = uri.path?.takeIf { it.isNotEmpty() && it != "/" } ?: ""
    return host + (if (uri.port > 0) ":${uri.port}" else "") + path
}

/** The stack's bookmarks (Homepage labels), first container first. */
val DockerStack.bookmarkLinks: List<Bookmark> get() = containers.mapNotNull { it.bookmark }

/** How serious a stack's status is, for the dot and the text colour. */
enum class StackSeverity { OK, WARNING, DANGER, IDLE }

data class StackStatus(val text: String, val severity: StackSeverity)

/** The card's status line, like the Mac app's: unhealthy first, then not started, stopped, partly stopped; a healthy stack says nothing. */
fun DockerStack.status(): StackStatus = when {
    unhealthyCount > 0 -> StackStatus("$unhealthyCount unhealthy", StackSeverity.DANGER)
    containers.isEmpty() -> StackStatus("Not started", StackSeverity.IDLE)
    runningCount == 0 -> StackStatus("Stopped", StackSeverity.IDLE)
    stoppedCount > 0 -> StackStatus("$stoppedCount stopped", StackSeverity.WARNING)
    else -> StackStatus("", StackSeverity.OK)
}

/** The line under the page title: "12 stacks · 20 containers · 19 running, 1 unhealthy". */
fun DockerSnapshot.summary(): String {
    val stackCount = stacks.count { !it.isStandalone }
    val running = containers.count { it.isRunning }
    val unhealthy = containers.count { it.isUnhealthy }
    val parts = mutableListOf<String>()
    if (stackCount > 0) parts += "$stackCount ${if (stackCount == 1) "stack" else "stacks"}"
    parts += "${containers.size} ${if (containers.size == 1) "container" else "containers"}"
    val state = buildList {
        add("$running running")
        if (containers.size - running > 0) add("${containers.size - running} stopped")
        if (unhealthy > 0) add("$unhealthy unhealthy")
    }.joinToString(", ")
    return (parts + state).joinToString(" · ")
}

/** The one-letter tile that stands in for a site icon: a hue from the name, so a stack keeps its colour. Same hash as the Mac app. */
object LetterTile {
    fun letter(name: String): String = name.firstOrNull()?.uppercaseChar()?.toString() ?: "?"

    /** 0 until 360, the same for the same name. (djb2 over unicode scalars, as on the Mac.) */
    fun hue(name: String): Int {
        var h = 5381L
        name.codePoints().forEach { h = (h * 33 + it) }
        return (h % 360).toInt().let { if (it < 0) it + 360 else it }
    }

    /** Which of [count] palette colours this name gets: stable for the same name, so a stack keeps its colour. */
    fun slot(name: String, count: Int): Int = hue(name) % count
}

/** A container's usage text on a card: "6% · 147 MB", or its state when it is not running. */
fun DockerContainer.usageText(formatBytes: (Long) -> String): String {
    if (!isRunning) return state
    val cpu = cpuPercent
    val mem = memoryUsedBytes
    return if (cpu == null || mem == null) "—" else "${"%.0f".format(cpu)}% · ${formatBytes(mem)}"
}

/** A container image split for display: the repository (which may be shortened in the middle) and the tag, which is never cut. */
data class ImageName(val repository: String, val tag: String?) {
    companion object {
        fun parse(image: String): ImageName {
            val at = image.indexOf('@')
            if (at >= 0) {
                val digest = image.substring(at + 1)
                return ImageName(image.substring(0, at), "@" + digest.take(19))
            }
            val colon = image.lastIndexOf(':')
            // A colon before the last slash belongs to a registry port (localhost:5000/app), not to a tag.
            return if (colon > image.lastIndexOf('/') && colon >= 0) ImageName(image.substring(0, colon), image.substring(colon)) else ImageName(image, null)
        }
    }
}
