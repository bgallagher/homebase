package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable

/** Mirrors `UpdatesSnapshot` in spec/models.schema.json: one parsed reading of the `updates` command. */
@Serializable
data class PendingUpdate(
    val name: String,
    /** apt's suite list, e.g. "noble-updates,noble-security". */
    val suite: String,
    val newVersion: String,
    val oldVersion: String? = null,
    val architecture: String,
    val isSecurity: Boolean,
) {
    val id: String get() = "$name:$architecture"
}

@Serializable
data class UpdatesSnapshot(
    val packages: List<PendingUpdate>,
    /** Packages pinned with `apt-mark hold`; apt will not upgrade them. */
    val held: List<String>,
    /** Unix time the package lists were last refreshed, when the server says. */
    val refreshedAt: Long? = null,
    val rebootRequired: Boolean,
) {
    val securityCount: Int get() = packages.count { it.isSecurity }
}

sealed class UpdatesParseError(message: String) : Exception(message) {
    object NotInstalled : UpdatesParseError("apt is not installed on this server.")
    class Malformed(val detail: String) : UpdatesParseError("Unexpected updates output: $detail")
}

/** Pure parser for the `updates` command output (sections `##apt`, `##upgradable`, `##held`, `##refreshed`, `##reboot`). */
object UpdatesParser {
    fun parse(output: String): UpdatesSnapshot {
        val sections = OverviewParser.splitSections(output)
        val status = sections["apt"]?.firstOrNull() ?: throw UpdatesParseError.Malformed("no ##apt section")
        if (status == "missing") throw UpdatesParseError.NotInstalled

        val packages = (sections["upgradable"] ?: emptyList()).mapNotNull(::parseLine)
        val held = sections["held"] ?: emptyList()
        val refreshed = sections["refreshed"]?.firstOrNull()?.toLongOrNull()
        return UpdatesSnapshot(packages, held, refreshed, rebootRequired = sections["reboot"]?.firstOrNull() == "yes")
    }

    private val LINE = Regex("^[ ]*(\\S+)[ ]+(\\S+)[ ]+(\\S+)(?:[ ]+(\\S.*))?$")

    /**
     * `name/suite[,suite] new-version arch [upgradable from: old-version]`. Anything else ("Listing...", warnings) is not a
     * package line and is skipped.
     */
    internal fun parseLine(line: String): PendingUpdate? {
        val m = LINE.matchEntire(line) ?: return null
        val (first, version, arch, rest) = m.destructured
        val slash = first.indexOf('/')
        if (slash < 0) return null
        val name = first.substring(0, slash)
        val suite = first.substring(slash + 1)
        if (name.isEmpty() || suite.isEmpty()) return null

        var old: String? = null
        val marker = "upgradable from: "
        val at = rest.indexOf(marker)
        if (at >= 0) {
            val tail = rest.substring(at + marker.length)
            val value = if (tail.endsWith("]")) tail.dropLast(1) else tail
            old = value.ifEmpty { null }
        }
        val isSecurity = suite.split(',').any { it.endsWith("-security") }
        return PendingUpdate(name, suite, version, old, arch, isSecurity)
    }
}
