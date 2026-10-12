package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable

/** Mirrors `Overview` in spec/models.schema.json: one parsed reading of the `overview` command. */
@Serializable
data class Overview(
    /** Hardware and system identity (from /sys/class/dmi, /etc/machine-id, uname). Empty when the server does not say. */
    val vendor: String,
    val product: String,
    val machineID: String,
    val kernel: String,
    /** Changes on every boot; how a reboot is recognised. */
    val bootID: String,
    /** The server's own IPv4 address, and its Tailscale IPv4 address. Null when unknown or Tailscale is not connected. */
    val ipAddress: String? = null,
    val tailscaleIP: String? = null,
    /** The server's clock at the poll (Unix seconds), its UTC offset in seconds and its zone abbreviation. */
    val serverTime: Long,
    val utcOffsetSeconds: Int,
    val timeZoneName: String,
    val hostname: String,
    val os: OS,
    val uptimeSeconds: Double,
    val load1: Double,
    val load5: Double,
    val load15: Double,
    val cores: Int,
    val cpu: CPUCounters,
    val memory: Memory,
    val disks: List<Disk>,
    val rebootRequired: Boolean,
    /** Names of containers whose health check is failing (empty if docker is absent). */
    val unhealthyContainers: List<String>,
    /** Packages apt can upgrade (0 if apt is absent), and those from a security suite. */
    val pendingUpdates: Int,
    val securityUpdates: Int,
) {
    @Serializable
    data class OS(val id: String, val name: String, val version: String, val prettyName: String)

    @Serializable
    data class Memory(val totalBytes: Long, val availableBytes: Long) {
        val usedBytes: Long get() = totalBytes - availableBytes
        val usedFraction: Double get() = if (totalBytes > 0) usedBytes.toDouble() / totalBytes else 0.0
    }

    @Serializable
    data class Disk(
        val filesystem: String,
        val mount: String,
        val totalBytes: Long,
        val usedBytes: Long,
        /** Used share of the space a non-root user can use, as `df` reports it (0 to 100). */
        val usePercent: Int,
    )

    /** Cumulative CPU counters from /proc/stat. Two readings give a utilisation percentage. */
    @Serializable
    data class CPUCounters(val total: Long, val idle: Long)

    /** "Hetzner vServer", or whatever part is known. */
    val modelName: String get() = listOf(vendor, product).filter { it.isNotEmpty() }.joinToString(" ")

    /** CPU use (0 to 100) between an earlier reading and this one, or null if no time passed. */
    fun cpuPercent(since: Overview): Double? {
        val total = cpu.total - since.cpu.total
        val idle = cpu.idle - since.cpu.idle
        if (total <= 0) return null
        return ((total - idle).toDouble() / total * 100).coerceIn(0.0, 100.0)
    }
}
