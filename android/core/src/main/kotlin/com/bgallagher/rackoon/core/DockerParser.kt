package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.roundToLong

/** Pure parser for the `docker` command output (sections `##docker`, `##ps`, `##stats`). */
object DockerParser {
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private class PSRow(
        val ID: String, val Names: String, val Image: String, val State: String, val Status: String,
        val HealthStatus: String? = null, val Ports: String? = null, val Labels: String? = null,
    )

    @Serializable
    private class StatsRow(val ID: String, val CPUPerc: String, val MemUsage: String)

    private class Stat(val cpu: Double?, val used: Long?, val limit: Long?)

    fun parse(output: String): DockerSnapshot {
        val sections = OverviewParser.splitSections(output)
        val status = sections["docker"]?.firstOrNull() ?: throw DockerParseError.Malformed("no ##docker section")
        if (status == "missing") throw DockerParseError.NotInstalled

        val psLines = sections["ps"] ?: emptyList()
        // Anything that is not a JSON row is docker's error text (daemon down, permission denied...).
        if (psLines.any { !it.startsWith("{") }) throw DockerParseError.Daemon(psLines.joinToString("\n"))

        val stats = HashMap<String, Stat>()
        for (line in sections["stats"] ?: emptyList()) {
            if (!line.startsWith("{")) continue
            val row = try { json.decodeFromString<StatsRow>(line) } catch (_: Exception) { continue }
            val mem = parseMemUsage(row.MemUsage)
            stats[row.ID] = Stat(parsePercent(row.CPUPerc), mem?.first, mem?.second)
        }

        val containers = psLines.map { line ->
            val row = try {
                json.decodeFromString<PSRow>(line)
            } catch (e: Exception) {
                throw DockerParseError.Malformed("ps row: ${e.message}")
            }
            val labels = parseLabels(row.Labels ?: "")
            val s = stats[row.ID]
            val configFiles = (labels["com.docker.compose.project.config_files"] ?: "").split(',').filter { it.isNotEmpty() }
            DockerContainer(
                id = row.ID, name = row.Names, image = row.Image,
                state = row.State, health = health(row.HealthStatus, row.Status), status = row.Status,
                ports = parsePorts(row.Ports ?: ""),
                project = labels["com.docker.compose.project"], service = labels["com.docker.compose.service"],
                workingDir = labels["com.docker.compose.project.working_dir"],
                configFile = configFiles.firstOrNull(), configFiles = configFiles,
                cpuPercent = s?.cpu, memoryUsedBytes = s?.used, memoryLimitBytes = s?.limit,
                bookmark = Bookmark.from(labels),
            )
        }
        return DockerSnapshot(containers)
    }

    /** Newer Docker reports HealthStatus; older versions only put it in the status text. */
    internal fun health(field: String?, status: String): String {
        if (!field.isNullOrEmpty()) return field
        if (status.contains("(unhealthy)")) return "unhealthy"
        if (status.contains("(healthy)")) return "healthy"
        if (status.contains("(health: starting)")) return "starting"
        return "none"
    }

    internal fun parseLabels(s: String): Map<String, String> {
        val map = LinkedHashMap<String, String>()
        // Labels are comma-separated key=value pairs. A value may itself contain commas (e.g. several compose files), so a
        // piece without "=" continues the previous value.
        var last: String? = null
        for (piece in s.split(',').filter { it.isNotEmpty() }) {
            val eq = piece.indexOf('=')
            if (eq >= 0) {
                val k = piece.substring(0, eq)
                map[k] = piece.substring(eq + 1)
                last = k
            } else if (last != null) {
                map[last] = (map[last] ?: "") + "," + piece
            }
        }
        return map
    }

    /** "127.0.0.1:8087->8080/tcp, [::]:8087->8080/tcp, 5432/tcp" -> published mappings only. */
    internal fun parsePorts(s: String): List<DockerContainer.PortMapping> {
        val seen = HashSet<DockerContainer.PortMapping>()
        val result = mutableListOf<DockerContainer.PortMapping>()
        for (part in s.split(',').map { it.trimBlanks() }) {
            val arrow = part.indexOf("->")
            if (arrow < 0) continue
            val left = part.substring(0, arrow)
            val right = part.substring(arrow + 2)
            val hostPort = left.split(':').filter { it.isNotEmpty() }.lastOrNull()?.toIntOrNull() ?: continue // skips ranges
            val rhs = right.split('/').filter { it.isNotEmpty() }
            if (rhs.size != 2) continue
            val containerPort = rhs[0].toIntOrNull() ?: continue
            val m = DockerContainer.PortMapping(hostPort, containerPort, rhs[1])
            if (seen.add(m)) result += m
        }
        return result
    }

    internal fun parsePercent(s: String): Double? = s.trim { it == '%' || it == ' ' }.toDoubleOrNull()

    /** "255.8MiB / 7.57GiB" */
    internal fun parseMemUsage(s: String): Pair<Long, Long>? {
        val parts = s.split(" / ")
        if (parts.size != 2) return null
        val used = parseSize(parts[0]) ?: return null
        val limit = parseSize(parts[1]) ?: return null
        return used to limit
    }

    private val units = mapOf(
        "B" to 1.0, "kB" to 1e3, "KB" to 1e3, "MB" to 1e6, "GB" to 1e9, "TB" to 1e12,
        "KiB" to 1024.0, "MiB" to 1_048_576.0, "GiB" to 1_073_741_824.0, "TiB" to 1_099_511_627_776.0,
    )

    internal fun parseSize(s: String): Long? {
        val t = s.trimBlanks()
        val i = t.indexOfFirst { !(it in '0'..'9' || it == '.') }
        if (i < 0) return null
        val n = t.substring(0, i).toDoubleOrNull() ?: return null
        val mult = units[t.substring(i)] ?: return null
        return (n * mult).roundToLong()
    }
}
