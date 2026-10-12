package com.bgallagher.rackoon.core

sealed class ParseError(message: String) : Exception(message) {
    class MissingSection(val name: String) : ParseError("missing section $name")
    class Malformed(val section: String, val detail: String) : ParseError("malformed $section: $detail")
}

/** Splits on single spaces, dropping empty pieces (Swift's `split(separator: " ")`). */
internal fun String.splitSpaces(): List<String> = split(' ').filter { it.isNotEmpty() }

/** Trims spaces and tabs only, like Swift's `CharacterSet.whitespaces`. */
internal fun String.trimBlanks(): String = trim { it == ' ' || it == '\t' }

/** Pure parser for the `overview` command output. No I/O, so it mirrors the Swift parser line for line. */
object OverviewParser {
    fun parse(output: String): Overview {
        val sections = splitSections(output)
        fun section(name: String): List<String> = sections[name] ?: throw ParseError.MissingSection(name)
        fun bad(s: String, d: String) = ParseError.Malformed(s, d)

        val hostname = section("hostname").firstOrNull() ?: ""

        val osMap = keyValues(section("os"))
        val osID = osMap["ID"] ?: throw bad("os", "no ID")
        val os = Overview.OS(
            id = osID,
            name = osMap["NAME"] ?: osID,
            version = osMap["VERSION_ID"] ?: "",
            prettyName = osMap["PRETTY_NAME"] ?: osMap["NAME"] ?: osID,
        )

        val uptime = section("uptime").firstOrNull()?.splitSpaces()?.firstOrNull()?.toDoubleOrNull() ?: throw bad("uptime", "no seconds")

        val load = section("loadavg").firstOrNull()?.splitSpaces()?.take(3)?.mapNotNull { it.toDoubleOrNull() } ?: emptyList()
        if (load.size != 3) throw bad("loadavg", "need 3 numbers")

        val cores = section("nproc").firstOrNull()?.toIntOrNull() ?: throw bad("nproc", "no number")

        // cpu  user nice system idle iowait irq softirq steal ...
        val stat = section("stat").firstOrNull()?.splitSpaces()?.drop(1)?.mapNotNull { it.toLongOrNull() } ?: emptyList()
        if (stat.size < 8) throw bad("stat", "need at least 8 counters")
        val cpu = Overview.CPUCounters(total = stat.take(8).sum(), idle = stat[3] + stat[4])

        val mem = keyValues(section("meminfo"), ':')
        fun kb(key: String): Long {
            val v = mem[key]?.splitSpaces()?.firstOrNull()?.toLongOrNull() ?: throw bad("meminfo", "no $key")
            return v * 1024
        }
        val memory = Overview.Memory(totalBytes = kb("MemTotal"), availableBytes = kb("MemAvailable"))

        val disks = mutableListOf<Overview.Disk>()
        for (line in section("df").drop(1)) {
            // Filesystem 1-blocks Used Available Capacity Mounted-on (the mount may contain spaces)
            val f = DF_LINE.matchEntire(line)?.groupValues?.drop(1) ?: continue
            val total = f[1].toLongOrNull() ?: continue
            val used = f[2].toLongOrNull() ?: continue
            val pct = f[4].dropLast(1).toIntOrNull() ?: continue
            disks += Overview.Disk(f[0], f[5], total, used, pct)
        }

        // Optional like `unhealthy`: output captured before this section existed still parses.
        val system = keyValues(sections["system"] ?: emptyList())
        val timeParts = (system["time"] ?: "").splitSpaces()
        val utcOffset = run {
            if (timeParts.size < 2 || timeParts[1].length != 5) return@run 0
            val sign = timeParts[1].first()
            if (sign != '+' && sign != '-') return@run 0
            val h = timeParts[1].substring(1, 3).toIntOrNull() ?: return@run 0
            val m = timeParts[1].substring(3, 5).toIntOrNull() ?: return@run 0
            (if (sign == '-') -1 else 1) * (h * 3600 + m * 60)
        }

        val reboot = section("reboot").firstOrNull() == "yes"
        // Optional: older output and hosts without docker have no names here.
        val unhealthy = sections["unhealthy"] ?: emptyList()
        val pending = sections["updates"]?.firstOrNull()?.toIntOrNull() ?: 0
        val security = sections["security"]?.firstOrNull()?.toIntOrNull() ?: 0

        return Overview(
            vendor = system["vendor"] ?: "", product = system["product"] ?: "", machineID = system["machine_id"] ?: "",
            kernel = system["kernel"] ?: "", bootID = system["boot_id"] ?: "",
            ipAddress = ipv4(system["ip"]), tailscaleIP = ipv4(system["tailscale_ip"]),
            serverTime = timeParts.firstOrNull()?.toLongOrNull() ?: 0, utcOffsetSeconds = utcOffset,
            timeZoneName = if (timeParts.size >= 3) timeParts[2] else "",
            hostname = hostname, os = os, uptimeSeconds = uptime,
            load1 = load[0], load5 = load[1], load15 = load[2], cores = cores,
            cpu = cpu, memory = memory, disks = disks, rebootRequired = reboot, unhealthyContainers = unhealthy,
            pendingUpdates = pending, securityUpdates = security,
        )
    }

    private val DF_LINE = Regex("^[ ]*(\\S+)[ ]+(\\S+)[ ]+(\\S+)[ ]+(\\S+)[ ]+(\\S+)[ ]+(.+)$")
    private val IPV4 = Regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")

    /** A dotted IPv4 address, or null. It is shown and copied, so anything else the command might print is dropped. */
    internal fun ipv4(value: String?): String? {
        val v = value?.trimBlanks() ?: return null
        if (!IPV4.matches(v) || !v.split('.').all { (it.toIntOrNull() ?: 256) <= 255 }) return null
        return v
    }

    internal fun splitSections(output: String): Map<String, List<String>> {
        val result = LinkedHashMap<String, MutableList<String>>()
        var current: String? = null
        for (line in output.split('\n')) {
            if (line.startsWith("##")) {
                current = line.drop(2)
                result[current] = mutableListOf()
            } else if (current != null && line.isNotEmpty()) {
                result.getOrPut(current) { mutableListOf() } += line
            }
        }
        return result
    }

    internal fun keyValues(lines: List<String>, separator: Char = '='): Map<String, String> {
        val map = LinkedHashMap<String, String>()
        for (line in lines) {
            val i = line.indexOf(separator)
            if (i < 0) continue
            val key = line.substring(0, i)
            var value = line.substring(i + 1).trimBlanks()
            if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) value = value.substring(1, value.length - 1)
            map[key] = value
        }
        return map
    }
}
