package com.bgallagher.rackoon.core

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI

// Alerts: everything that needs the user, across every server, with a memory. Mirrors Alerts.swift. The app feeds each
// server's readings in by source (its connection, the Overview's attention items, the services scan, a light container check,
// certificate checks of its bookmarks); `AlertRules` turns a reading into signals and `AlertBook` keeps the alerts: when each
// was first and last seen, when it went away, whether the user has seen or muted it, and which ones are new enough to notify
// about. Pure, so the same rules can run in a relay or on a phone. Times are epoch milliseconds.
//
// Not ported yet: `AlertRules.storage` (Unraid's array), because the Kotlin core has no Unraid model.

typealias AlertSeverity = AttentionItem.Severity

/** Higher is worse, for sorting and for "did it get worse". */
val AttentionItem.Severity.rank: Int
    get() = when (this) {
        AttentionItem.Severity.INFO -> 0
        AttentionItem.Severity.WARNING -> 1
        AttentionItem.Severity.CRITICAL -> 2
    }

/**
 * Where an alert's reading comes from. A reading only resolves alerts of its own source, so a check that did not run never
 * clears another check's alerts.
 */
@Serializable
enum class AlertSource(val raw: String) {
    @SerialName("connection") CONNECTION("connection"),
    @SerialName("overview") OVERVIEW("overview"),
    @SerialName("services") SERVICES("services"),
    @SerialName("containers") CONTAINERS("containers"),
    @SerialName("storage") STORAGE("storage"),
    @SerialName("certificates") CERTIFICATES("certificates"),
}

/** What an alert is about, for grouping and filters. */
@Serializable
enum class AlertCategory(val title: String) {
    @SerialName("connection") CONNECTION("Connection"),
    @SerialName("disk") DISK("Disk"),
    @SerialName("containers") CONTAINERS("Containers"),
    @SerialName("services") SERVICES("Services"),
    @SerialName("updates") UPDATES("Updates"),
    @SerialName("storage") STORAGE("Storage"),
    @SerialName("certificates") CERTIFICATES("Certificates"),
}

/** Where to go to deal with an alert: a screen and, when it helps, the thing on it. */
@Serializable
data class AlertFix(
    val screen: String,
    /** A Docker stack id, a service id or a bookmark address. */
    val target: String? = null,
)

/** One thing a reading found wrong, before the book gives it a history. */
data class AlertSignal(
    /** Stable within the server and source: `disk_high:/`, `service_failed:system/x.service`. */
    val key: String,
    val category: AlertCategory,
    val severity: AlertSeverity,
    val title: String,
    val detail: String? = null,
    val fix: AlertFix? = null,
)

@Serializable
data class ServerAlert(
    /** `<server id>|<source>|<key>`. */
    val id: String,
    val serverID: String,
    val serverName: String,
    val source: AlertSource,
    val key: String,
    val category: AlertCategory,
    val severity: AlertSeverity,
    val title: String,
    val detail: String? = null,
    val fix: AlertFix? = null,
    val firstSeen: Long,
    val lastSeen: Long,
    /** When the condition went away; null while it is active. */
    val resolvedAt: Long? = null,
    /** The user has seen it: it stays listed but stops counting in badges. */
    val acknowledged: Boolean = false,
) {
    val isActive: Boolean get() = resolvedAt == null
}

// The book

@Serializable
class AlertBook {
    /** Active alerts and resolved ones from the last [HISTORY_DAYS]. */
    var alerts: List<ServerAlert> = emptyList()
        private set

    /** ServerAlert ids the user muted: never counted or notified, shown only under Muted. */
    var muted: Set<String> = emptySet()
        private set

    /**
     * `<server id>|<source>` pairs that have had at least one reading, so the very first reading of a server (or of a new
     * check) does not notify about everything it finds at once.
     */
    var baselined: Set<String> = emptySet()
        private set

    /**
     * Records one reading of `source` on a server. Returns the alerts worth a notification: new ones (warning or worse) and
     * ones that just became critical, never on the source's first reading and never muted ones.
     */
    fun apply(server: String, serverName: String, source: AlertSource, signals: List<AlertSignal>, now: Long): List<ServerAlert> {
        val baselineKey = "$server|${source.raw}"
        val firstReading = baselineKey !in baselined
        baselined = baselined + baselineKey
        val list = alerts.toMutableList()
        val raised = mutableListOf<ServerAlert>()
        val seen = HashSet<String>()
        for (signal in signals) {
            val id = id(server, source, signal.key)
            if (!seen.add(id)) continue
            val i = list.indexOfFirst { it.id == id && it.isActive }
            if (i >= 0) {
                val old = list[i]
                val worse = signal.severity == AttentionItem.Severity.CRITICAL && old.severity != AttentionItem.Severity.CRITICAL
                val updated = old.copy(
                    severity = signal.severity, title = signal.title, detail = signal.detail, fix = signal.fix,
                    category = signal.category, serverName = serverName, lastSeen = now,
                    acknowledged = if (worse) false else old.acknowledged,
                )
                list[i] = updated
                if (worse && !firstReading && id !in muted) raised += updated
            } else {
                val alert = ServerAlert(
                    id = id, serverID = server, serverName = serverName, source = source, key = signal.key,
                    category = signal.category, severity = signal.severity, title = signal.title, detail = signal.detail,
                    fix = signal.fix, firstSeen = now, lastSeen = now, resolvedAt = null, acknowledged = false,
                )
                list += alert
                if (!firstReading && signal.severity != AttentionItem.Severity.INFO && id !in muted) raised += alert
            }
        }
        // Gone from this source's reading: resolved.
        for (i in list.indices) {
            val a = list[i]
            if (a.serverID == server && a.source == source && a.isActive && a.id !in seen) list[i] = a.copy(resolvedAt = now)
        }
        alerts = list
        prune(now)
        return raised
    }

    /** Active alerts, worst first, then oldest first. `includeMuted` adds the muted ones. */
    fun active(server: String? = null, includeMuted: Boolean = false): List<ServerAlert> =
        alerts.filter { it.isActive && (server == null || it.serverID == server) && (includeMuted || it.id !in muted) }
            .sortedWith(compareByDescending<ServerAlert> { it.severity.rank }.thenBy { it.firstSeen })

    fun mutedAlerts(server: String? = null): List<ServerAlert> =
        alerts.filter { it.isActive && it.id in muted && (server == null || it.serverID == server) }
            .sortedByDescending { it.firstSeen }

    /** Resolved alerts, most recent first. */
    fun history(server: String? = null): List<ServerAlert> =
        alerts.filter { !it.isActive && (server == null || it.serverID == server) }
            .sortedByDescending { it.resolvedAt ?: Long.MIN_VALUE }

    /** What a badge counts: active warnings and critical ones the user has neither seen nor muted. */
    fun unseenCount(server: String? = null): Int =
        active(server).count { !it.acknowledged && it.severity != AttentionItem.Severity.INFO }

    fun worstUnseen(server: String? = null): AlertSeverity? =
        active(server).filter { !it.acknowledged && it.severity != AttentionItem.Severity.INFO }.map { it.severity }.maxByOrNull { it.rank }

    fun acknowledge(id: String, seen: Boolean = true) {
        alerts = alerts.map { if (it.id == id && it.isActive) it.copy(acknowledged = seen) else it }
    }

    fun acknowledgeAll(server: String? = null) {
        alerts = alerts.map { if (it.isActive && (server == null || it.serverID == server)) it.copy(acknowledged = true) else it }
    }

    fun mute(id: String, on: Boolean = true) {
        muted = if (on) muted + id else muted - id
    }

    fun clearHistory(server: String? = null) {
        alerts = alerts.filterNot { !it.isActive && (server == null || it.serverID == server) }
    }

    /** A removed server's alerts, mutes and baselines go with it. Returns whether anything changed. */
    fun forget(serverID: String): Boolean {
        val before = Triple(alerts.size, muted.size, baselined.size)
        alerts = alerts.filterNot { it.serverID == serverID }
        muted = muted.filterNot { it.startsWith("$serverID|") }.toSet()
        baselined = baselined.filterNot { it.startsWith("$serverID|") }.toSet()
        return before != Triple(alerts.size, muted.size, baselined.size)
    }

    /** Resolved alerts older than [HISTORY_DAYS] go, and the history never grows past [HISTORY_LIMIT]. */
    internal fun prune(now: Long) {
        val cutoff = now - HISTORY_DAYS * DAY_MILLIS
        var list = alerts.filterNot { (it.resolvedAt ?: Long.MAX_VALUE) < cutoff }
        val resolved = list.filter { !it.isActive }
        if (resolved.size > HISTORY_LIMIT) {
            val drop = resolved.sortedBy { it.resolvedAt ?: Long.MIN_VALUE }.take(resolved.size - HISTORY_LIMIT).map { it.id }.toSet()
            list = list.filterNot { !it.isActive && it.id in drop }
        }
        alerts = list
    }

    fun copy(): AlertBook = AlertBook().also { it.alerts = alerts; it.muted = muted; it.baselined = baselined }

    override fun equals(other: Any?): Boolean =
        other is AlertBook && other.alerts == alerts && other.muted == muted && other.baselined == baselined

    override fun hashCode(): Int = (alerts.hashCode() * 31 + muted.hashCode()) * 31 + baselined.hashCode()

    companion object {
        const val HISTORY_DAYS = 7
        const val HISTORY_LIMIT = 300
        internal const val DAY_MILLIS = 86_400_000L

        fun id(server: String, source: AlertSource, key: String): String = "$server|${source.raw}|$key"
    }
}

// Rules: from readings to signals

object AlertRules {
    /** The server's connection: not answering, or blocked by its host key or a refused login. */
    fun connection(error: String?, blocked: String?): List<AlertSignal> {
        if (blocked != null) {
            val changed = blocked.lowercase().contains("changed")
            return listOf(
                AlertSignal(
                    key = if (changed) "host_key_changed" else "host_key_unknown", category = AlertCategory.CONNECTION,
                    severity = if (changed) AttentionItem.Severity.CRITICAL else AttentionItem.Severity.INFO,
                    title = if (changed) "Host key changed" else "Host key not trusted yet",
                    detail = blocked, fix = AlertFix("overview"),
                ),
            )
        }
        if (!error.isNullOrEmpty()) {
            val explained = ConnectionFailure.explain(error)
            val refused = error.contains("Permission denied")
            return listOf(
                AlertSignal(
                    key = if (refused) "login_refused" else "not_answering", category = AlertCategory.CONNECTION,
                    severity = AttentionItem.Severity.CRITICAL,
                    title = if (refused) "Login refused" else "Not answering",
                    detail = explained?.headline ?: error.split('\n').firstOrNull { it.isNotEmpty() }, fix = AlertFix("overview"),
                ),
            )
        }
        return emptyList()
    }

    /** The Overview's needs-attention items (disk, unhealthy containers, security updates, reboot required). */
    fun overview(overview: Overview): List<AlertSignal> = Attention.evaluate(overview).map { item ->
        val category = when {
            item.id.startsWith("disk") -> AlertCategory.DISK
            item.id.startsWith("container") -> AlertCategory.CONTAINERS
            else -> AlertCategory.UPDATES
        }
        val title = when {
            item.id == "security_updates" -> "Security updates available"
            item.id == "reboot_required" -> "Reboot required"
            item.id.startsWith("disk_high") -> "Disk almost full"
            else -> "Container unhealthy"
        }
        AlertSignal(item.id, category, item.severity, title, item.message, AlertFix(item.fix))
    }

    /** Services the user watches (shown on the Services screen) that failed, crash-loop or are stopped although they start at boot. */
    fun services(snapshot: ServicesSnapshot, isWatched: (DiscoveredService) -> Boolean): List<AlertSignal> =
        snapshot.services.filter(isWatched).mapNotNull { s ->
            val fix = AlertFix("services", target = s.id)
            when {
                s.status == DiscoveredService.Status.FAILED -> AlertSignal(
                    "service_failed:${s.id}", AlertCategory.SERVICES, AttentionItem.Severity.CRITICAL, "${s.name} failed",
                    listOfNotNull(s.unit, s.result?.let { "result: $it" }).joinToString(" · "), fix,
                )
                s.status == DiscoveredService.Status.RESTARTING -> AlertSignal(
                    "service_crashing:${s.id}", AlertCategory.SERVICES, AttentionItem.Severity.CRITICAL, "${s.name} keeps crashing",
                    "systemd has restarted ${s.unit ?: s.name} ${s.restarts} time${if (s.restarts == 1) "" else "s"}.", fix,
                )
                s.status == DiscoveredService.Status.STOPPED && s.enabledAtBoot == true -> AlertSignal(
                    "service_stopped:${s.id}", AlertCategory.SERVICES, AttentionItem.Severity.WARNING, "${s.name} is stopped",
                    "${s.unit ?: s.name} starts at boot but is not running now.", fix,
                )
                else -> null
            }
        }

    /**
     * Containers that are down: restarting over and over, dead, or exited with an error. Exit codes 0 (finished), 130, 137 and
     * 143 (stopped by a signal, as `docker stop` does) are not problems, nor is a container never started.
     */
    fun containers(reading: DockerStatesReading): List<AlertSignal> {
        when (val problem = reading.problem) {
            DockerStatesReading.Problem.NotInstalled -> return emptyList()
            DockerStatesReading.Problem.PermissionDenied -> return listOf(
                AlertSignal(
                    "docker_needs_sudo", AlertCategory.CONTAINERS, AttentionItem.Severity.INFO, "Containers not checked",
                    "Docker refuses this user, so background checks can't see containers. Unlock Docker with sudo on the Docker screen to look.",
                    AlertFix("docker"),
                ),
            )
            is DockerStatesReading.Problem.Other -> return listOf(
                AlertSignal("docker_unreadable", AlertCategory.CONTAINERS, AttentionItem.Severity.WARNING, "Docker did not answer", problem.text, AlertFix("docker")),
            )
            null -> {}
        }
        return reading.containers.mapNotNull { c ->
            val stack = if (c.project.isEmpty()) "standalone/${c.name}" else c.project
            val fix = AlertFix("docker", target = stack)
            when (c.state) {
                "restarting" -> AlertSignal(
                    "container_down:${c.name}", AlertCategory.CONTAINERS, AttentionItem.Severity.CRITICAL, "${c.name} keeps restarting", c.status, fix,
                )
                "dead" -> AlertSignal(
                    "container_down:${c.name}", AlertCategory.CONTAINERS, AttentionItem.Severity.CRITICAL, "${c.name} is dead",
                    "Docker could not stop or remove it cleanly.", fix,
                )
                "exited" -> {
                    val code = c.exitCode
                    if (code == null || code in listOf(0, 130, 137, 143)) null
                    else AlertSignal(
                        "container_down:${c.name}", AlertCategory.CONTAINERS, AttentionItem.Severity.WARNING, "${c.name} stopped with an error", c.status, fix,
                    )
                }
                else -> null
            }
        }
    }

    /** Days before expiry at which a certificate warns, and becomes critical. */
    const val CERTIFICATE_WARNING_DAYS = 21.0
    const val CERTIFICATE_CRITICAL_DAYS = 7.0

    /** Bookmarked https sites whose certificate expires soon or has expired. Sites that could not be reached say nothing. */
    fun certificates(checks: List<CertificateCheck>, now: Long): List<AlertSignal> = checks.mapNotNull { check ->
        val expires = check.expires ?: return@mapNotNull null
        val days = (expires - now).toDouble() / AlertBook.DAY_MILLIS
        val fix = AlertFix("bookmarks", target = check.url)
        when {
            days <= 0 -> AlertSignal(
                "cert:${check.host}", AlertCategory.CERTIFICATES, AttentionItem.Severity.CRITICAL,
                "Certificate expired: ${check.host}", "It expired ${days(-days)} ago.", fix,
            )
            days > CERTIFICATE_WARNING_DAYS -> null
            else -> AlertSignal(
                "cert:${check.host}", AlertCategory.CERTIFICATES,
                if (days <= CERTIFICATE_CRITICAL_DAYS) AttentionItem.Severity.CRITICAL else AttentionItem.Severity.WARNING,
                "Certificate expires soon: ${check.host}", "It expires in ${days(days)}.", fix,
            )
        }
    }

    internal fun days(d: Double): String {
        val n = kotlin.math.floor(d).toInt()
        return if (n < 1) "less than a day" else "$n day${if (n == 1) "" else "s"}"
    }
}

/** When a site's TLS certificate expires, as the device saw it. */
@Serializable
data class CertificateCheck(
    val url: String,
    val host: String,
    /** Null when the site could not be reached or showed no certificate. Epoch milliseconds. */
    val expires: Long? = null,
    val checkedAt: Long,
) {
    companion object {
        /** The https addresses worth checking among bookmark addresses: one per host and port. */
        fun targets(hrefs: List<String>): List<String> {
            val seen = HashSet<String>()
            return hrefs.mapNotNull { href ->
                val uri = try { URI(href) } catch (_: Exception) { return@mapNotNull null }
                if (uri.scheme?.lowercase() != "https") return@mapNotNull null
                val host = uri.host?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                val port = uri.port.takeIf { it >= 0 }
                if (!seen.add("${host.lowercase()}:${port ?: 443}")) return@mapNotNull null
                "https://$host${port?.let { ":$it" } ?: ""}/"
            }
        }
    }
}

// The light container check (spec `docker_states`)

@Serializable
data class DockerStatesReading(val containers: List<Container>, val problem: Problem? = null) {
    @Serializable
    data class Container(
        val id: String,
        val name: String,
        /** created, running, restarting, exited, paused, dead, removing. */
        val state: String,
        /** "Exited (1) 3 hours ago", "Up 2 days (healthy)". */
        val status: String,
        val project: String,
        /** The `homepage.href` label, for certificate checks. */
        val href: String,
    ) {
        /** The exit code an exited container reports in its status. */
        val exitCode: Int?
            get() {
                val open = status.indexOf("Exited (")
                if (open < 0) return null
                val start = open + "Exited (".length
                val close = status.indexOf(')', start)
                if (close < 0) return null
                return status.substring(start, close).toIntOrNull()
            }
    }

    /** Encoded like Swift's Codable enum (`{"notInstalled":{}}`, `{"other":{"_0":"..."}}`), so golden files are shared. */
    @Serializable(with = ProblemSerializer::class)
    sealed class Problem {
        object NotInstalled : Problem() { override fun toString() = "NotInstalled" }
        object PermissionDenied : Problem() { override fun toString() = "PermissionDenied" }
        data class Other(val text: String) : Problem()
    }

    internal object ProblemSerializer : KSerializer<Problem> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("DockerStatesReading.Problem")

        override fun serialize(encoder: Encoder, value: Problem) {
            val json = encoder as? JsonEncoder ?: throw SerializationException("Problem is only encoded as JSON")
            val element = when (value) {
                Problem.NotInstalled -> JsonObject(mapOf("notInstalled" to JsonObject(emptyMap())))
                Problem.PermissionDenied -> JsonObject(mapOf("permissionDenied" to JsonObject(emptyMap())))
                is Problem.Other -> JsonObject(mapOf("other" to JsonObject(mapOf("_0" to JsonPrimitive(value.text)))))
            }
            json.encodeJsonElement(element)
        }

        override fun deserialize(decoder: Decoder): Problem {
            val json = decoder as? JsonDecoder ?: throw SerializationException("Problem is only decoded from JSON")
            val obj = json.decodeJsonElement().jsonObject
            return when {
                "notInstalled" in obj -> Problem.NotInstalled
                "permissionDenied" in obj -> Problem.PermissionDenied
                "other" in obj -> Problem.Other(obj.getValue("other").jsonObject.getValue("_0").jsonPrimitive.content)
                else -> throw SerializationException("unknown problem $obj")
            }
        }
    }
}

object DockerStatesParser {
    fun parse(output: String): DockerStatesReading {
        val containers = mutableListOf<DockerStatesReading.Container>()
        val other = mutableListOf<String>()
        for (line in output.split('\n')) {
            if (line.isEmpty() || line.trimBlanks().isEmpty()) continue
            val f = line.split('\t')
            if (f.size >= 6 && DockerSession.isContainerID(f[0])) {
                containers += DockerStatesReading.Container(f[0], f[1], f[2], f[3], f[4], f[5])
            } else {
                other += line
            }
        }
        if (containers.isNotEmpty() || other.isEmpty()) return DockerStatesReading(containers, null)
        val text = other.joinToString("\n")
        val lower = text.lowercase()
        if (lower.contains("not found") || lower.contains("no such file")) return DockerStatesReading(emptyList(), DockerStatesReading.Problem.NotInstalled)
        if (DockerAccess.isPermissionProblem(text)) return DockerStatesReading(emptyList(), DockerStatesReading.Problem.PermissionDenied)
        return DockerStatesReading(emptyList(), DockerStatesReading.Problem.Other(text.take(300)))
    }
}

class DockerStatesSession(private val transport: SSHTransport) {
    companion object {
        val command: String get() = SpecCommands.script("docker_states")
    }

    /** One reading, or null when ssh itself failed (the connection alert covers that). */
    suspend fun read(): DockerStatesReading? {
        val result = try {
            transport.run(command, timeoutMillis = 15_000)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return null
        }
        if (result.exitCode != 0) return null
        return DockerStatesParser.parse(result.stdout)
    }
}
