package com.bgallagher.rackoon.demo

import com.bgallagher.rackoon.core.Server
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.security.MessageDigest
import java.util.Base64
import kotlin.math.cos
import kotlin.math.sin

/** The made-up servers. Process-wide, so what an action changes is still changed when the screen is left and opened again. */
object DemoWorlds {
    val servers = listOf(
        Server(id = "demo-homelab", name = "homelab", host = "homelab.demo", user = "ubuntu"),
        Server(id = "demo-garage", name = "garage-nuc", host = "garage-nuc.demo", user = "pi"),
        Server(id = "demo-nas", name = "old-nas", host = "old-nas.demo", user = "admin"),
    )

    private val worlds = HashMap<String, DemoWorld>()

    @Synchronized fun worldFor(host: String): DemoWorld = worlds.getOrPut(host) {
        when (host) {
            "garage-nuc.demo" -> DemoData.garage()
            "old-nas.demo" -> DemoData.homelab().also { it.unreachable = true }   // always times out: the "can't reach" screens
            else -> DemoData.homelab()
        }
    }
}

class DemoContainer(
    var id: String,
    val name: String,
    val image: String,
    val project: String?,
    val service: String?,
    var state: String = "running",
    var health: String = "none",
    val ports: String = "",
    val cpu: Double = 0.3,
    val memMb: Double = 50.0,
    val labels: MutableMap<String, String> = LinkedHashMap(),
    var restarts: Int = 0,
    var startedAt: Long = System.currentTimeMillis() - 3 * 86_400_000L,
)

/** One made-up server: what it reports, its containers and the files of its stacks. Mutated by the actions the app runs. */
class DemoWorld(
    val hostname: String,
    val prettyOs: String,
    val osId: String,
    val cores: Int,
    val memTotalKb: Long,
    val diskTotal: Long,
    val diskUsed: Long,
    val ip: String,
    val tailscaleIp: String,
    seedUpdates: Int,
    seedSecurity: Int,
    seedReboot: Boolean,
    val containers: MutableList<DemoContainer>,
) {
    @Volatile var unreachable = false

    // MARK: apt (Updates screen)

    class Pkg(val name: String, val suite: String, val newVersion: String, val oldVersion: String, val security: Boolean)

    val pending: MutableList<Pkg> = run {
        val sec = listOf(
            Pkg("openssl", "noble-updates,noble-security", "3.0.13-0ubuntu3.5", "3.0.13-0ubuntu3.4", true),
            Pkg("libssl3t64", "noble-updates,noble-security", "3.0.13-0ubuntu3.5", "3.0.13-0ubuntu3.4", true),
            Pkg("ubuntu-pro-client", "noble-infra-security", "33.3~24.04", "33.2~24.04", true),
        )
        val other = listOf(
            Pkg("libc6", "noble-updates", "2.39-0ubuntu8.4", "2.39-0ubuntu8.3", false),
            Pkg("linux-image-generic", "noble-updates", "6.8.0-52.53", "6.8.0-51.52", false),
            Pkg("curl", "noble-updates", "8.5.0-2ubuntu10.6", "8.5.0-2ubuntu10.5", false),
            Pkg("tzdata", "noble-updates", "2025b-0ubuntu0.24.04", "2024b-0ubuntu0.24.04", false),
        )
        (sec.take(seedSecurity) + other.take(maxOf(seedUpdates - seedSecurity, 0))).toMutableList()
    }
    val updates: Int get() = pending.size
    val security: Int get() = pending.count { it.security }
    val held: List<String> = if (seedUpdates > 0) listOf("docker-ce") else emptyList()
    @Volatile var refreshedAt: Long = System.currentTimeMillis() / 1000 - 3 * 3600
    @Volatile var rebootRequired: Boolean = seedReboot
    @Volatile var bootId: String = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"

    fun updatesOutput(): String = buildString {
        append("##apt\nok\n##upgradable\nListing...\n")
        pending.forEach { append("${it.name}/${it.suite} ${it.newVersion} amd64 [upgradable from: ${it.oldVersion}]\n") }
        append("##held\n${held.joinToString("\n")}${if (held.isEmpty()) "" else "\n"}##refreshed\n$refreshedAt\n##reboot\n${if (rebootRequired) "yes" else "no"}\n")
    }

    /** What an install does: the chosen packages (or all) leave the list; a new kernel asks for a reboot. */
    fun applyUpgrade(names: List<String>?) {
        val done = pending.filter { names == null || it.name in names }
        if (done.any { it.name.startsWith("linux-image") }) rebootRequired = true
        pending.removeAll(done.toSet())
    }

    /** A reboot: the server stops answering for about 15 seconds, then comes back with a new boot id. */
    fun reboot() {
        Thread {
            Thread.sleep(2000); unreachable = true
            Thread.sleep(13000); bootId = java.util.UUID.randomUUID().toString(); rebootRequired = false; unreachable = false
        }.also { it.isDaemon = true }.start()
    }
    private val born = System.currentTimeMillis()
    private val stackRoot = "/opt/stacks"
    val files = LinkedHashMap<String, String>()
    private var nextId = 0x4d3e00000000L

    init { for (p in projects()) { files["$stackRoot/$p/compose.yaml"] = composeText(p) } }

    fun projects(): List<String> = containers.mapNotNull { it.project }.distinct().sorted()
    /** Folders of stacks created from the app (everything else lives under /opt/stacks/<project>). */
    val stackDirs = HashMap<String, String>()
    fun dir(project: String) = stackDirs[project] ?: "$stackRoot/$project"
    fun freshId(): String { nextId += 0x1f3a7; return "%012x".format(nextId) }

    // MARK: what the commands print

    private fun seconds() = (System.currentTimeMillis() - born) / 1000.0

    fun overviewOutput(): String {
        val t = seconds()
        val totalPerSec = cores * 100.0
        val busy = totalPerSec * (0.12 * t + 0.08 * 7 * (1 - cos(t / 7)))
        val idle = totalPerSec * t - busy
        val base = 1_400_000L
        val usedKb = (memTotalKb * (0.28 + 0.02 * sin(t / 11))).toLong()
        val uptime = 3 * 86_400 + 11 * 3600 + t
        val unhealthy = containers.filter { it.health == "unhealthy" }.joinToString("\n") { it.name }
        return buildString {
            append("##hostname\n$hostname\n##os\nPRETTY_NAME=\"$prettyOs\"\nNAME=\"$osId\"\nID=$osId\n")
            append("##uptime\n%.2f 9999.00\n".format(uptime))
            append("##loadavg\n%.2f 0.40 0.30 1/400 12345\n".format(0.4 + 0.2 * sin(t / 5)))
            append("##nproc\n$cores\n")
            append("##stat\ncpu  ${base + busy.toLong()} 100 ${base / 2} ${base * 20 + idle.toLong()} 500 0 900 0 0 0\n")
            append("##meminfo\nMemTotal:        $memTotalKb kB\nMemAvailable:    ${memTotalKb - usedKb} kB\n")
            append("##df\nFilesystem        1-blocks        Used   Available Capacity Mounted on\n")
            append("/dev/sda1      $diskTotal $diskUsed ${diskTotal - diskUsed}      ${diskUsed * 100 / diskTotal}% /\n")
            append("##system\nvendor=Demo\nproduct=Rackoon demo\nmachine_id=0123456789abcdef0123456789abcdef\nkernel=6.8.0-146-generic\n")
            append("boot_id=$bootId\ntime=${System.currentTimeMillis() / 1000} +0000 UTC\nip=$ip\ntailscale_ip=$tailscaleIp\n")
            append("##reboot\n${if (rebootRequired) "yes" else "no"}\n##updates\n$updates\n##security\n$security\n##unhealthy\n$unhealthy\n")
        }
    }

    fun dockerOutput(): String {
        val t = seconds()
        val ps = containers.joinToString("\n") { c ->
            val labels = LinkedHashMap<String, String>()
            if (c.project != null) {
                labels["com.docker.compose.project.config_files"] = "${dir(c.project)}/compose.yaml"
                labels["com.docker.compose.project.working_dir"] = dir(c.project)
                labels["com.docker.compose.project"] = c.project
                labels["com.docker.compose.service"] = c.service ?: c.name
            }
            labels.putAll(c.labels)
            buildJsonObject {
                put("CreatedAt", "2026-10-09 09:00:00 +0000 UTC")
                put("HealthStatus", if (c.health == "none") "none" else c.health)
                put("ID", c.id)
                put("Image", c.image)
                put("Labels", labels.entries.joinToString(",") { "${it.key}=${it.value}" })
                put("Names", c.name)
                put("Ports", c.ports)
                put("RunningFor", "3 days ago")
                put("State", c.state)
                put("Status", statusText(c))
            }.toString()
        }
        val stats = containers.filter { it.state == "running" }.mapIndexed { i, c ->
            val cpu = (c.cpu * (1 + 0.3 * sin(t / 3 + i))).coerceAtLeast(0.0)
            buildJsonObject {
                put("BlockIO", "0B / 0B"); put("CPUPerc", "%.2f%%".format(cpu)); put("ID", c.id)
                put("MemPerc", "1.00%"); put("MemUsage", "%.1fMiB / 15.6GiB".format(c.memMb)); put("Name", c.name)
                put("NetIO", "1kB / 1kB"); put("PIDs", "10")
            }.toString()
        }.joinToString("\n")
        return "##docker\nok\n##ps\n$ps\n##stats\n$stats\n"
    }

    private fun statusText(c: DemoContainer): String {
        val mins = (System.currentTimeMillis() - c.startedAt) / 60_000
        val ago = when { mins < 2 -> "a minute"; mins < 120 -> "$mins minutes"; mins < 2 * 1440 -> "${mins / 60} hours"; else -> "${mins / 1440} days" }
        return when (c.state) {
            "running" -> "Up $ago" + when (c.health) { "healthy" -> " (healthy)"; "unhealthy" -> " (unhealthy)"; else -> "" }
            "restarting" -> "Restarting (1) 12 seconds ago"
            else -> "Exited (0) $ago ago"
        }
    }

    // MARK: files

    fun composeText(project: String): String = buildString {
        append("services:\n")
        for (c in containers.filter { it.project == project }) {
            append("  ${c.service}:\n    image: ${c.image}\n    container_name: ${c.name}\n")
            if (c.ports.contains("->")) {
                append("    ports:\n")
                Regex("""(\d+)->(\d+)/tcp""").findAll(c.ports).map { it.groupValues }.distinct().forEach { append("      - \"${it[1]}:${it[2]}\"\n") }
            }
            append("    restart: unless-stopped\n")
            val homepage = c.labels.filterKeys { it.startsWith("homepage.") }
            if (homepage.isNotEmpty()) {
                append("    labels:\n")
                homepage.forEach { (k, v) -> append("      - $k=$v\n") }
            }
        }
    }

    fun sha(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    fun readFile(path: String): String {
        val text = files[path] ?: return "##missing\n"
        val b64 = if (text.isEmpty()) "" else Base64.getEncoder().encodeToString(text.toByteArray())
        return "##meta\n1790000000 644 root:root\n##sha256\n${sha(text)}\n##content\n$b64\n"
    }

    /** The `file_write` command: the sha guard, then the new content. Returns (output, exit code). */
    fun writeFile(path: String, expectedSha: String?, content: String): Pair<String, Int> {
        val current = files[path]
        val matches = if (expectedSha != null) current != null && sha(current) == expectedSha else current == null
        if (!matches) return "##changed\n" to 3
        files[path] = content
        return "##saved\n${sha(content)}\n" to 0
    }

    /** After an `up -d` the containers reflect their compose file: services that have no container yet are created, and Homepage labels are re-read from its text. */
    fun applyCompose(project: String) {
        val text = files["${dir(project)}/compose.yaml"] ?: return
        run {
            var current: String? = null
            val images = LinkedHashMap<String, String>()
            val ports = HashMap<String, String>()
            for (line in text.lines()) {
                Regex("""^  ([A-Za-z0-9_.-]+):\s*$""").find(line)?.let { current = it.groupValues[1] }
                Regex("""^\s+image:\s*"?([^"\s]+)"?""").find(line)?.let { m -> current?.let { images[it] = m.groupValues[1] } }
                Regex("""^\s*-\s*"?(?:[^":]+:)?(\d+):(\d+)"?\s*$""").find(line)?.let { m -> current?.let { ports[it] = "0.0.0.0:${m.groupValues[1]}->${m.groupValues[2]}/tcp" } }
            }
            for ((service, image) in images) {
                if (containers.none { it.project == project && it.service == service }) {
                    containers += DemoContainer(freshId(), "${project}-$service-1", image, project, service, ports = ports[service].orEmpty(), cpu = 0.2, memMb = 40.0, startedAt = System.currentTimeMillis())
                }
            }
        }
        var service: String? = null
        val found = HashMap<String, MutableMap<String, String>>()
        for (line in text.lines()) {
            Regex("""^  ([A-Za-z0-9_.-]+):\s*$""").find(line)?.let { service = it.groupValues[1] }
            Regex("""^\s*-\s*"?(homepage\.[a-z]+)=(.*?)"?\s*$""").find(line)?.let { m ->
                service?.let { found.getOrPut(it) { LinkedHashMap() }[m.groupValues[1]] = m.groupValues[2] }
            }
        }
        for (c in containers.filter { it.project == project }) {
            val labels = found[c.service].orEmpty()
            if (c.labels.filterKeys { it.startsWith("homepage.") } != labels) {
                c.labels.keys.removeAll { it.startsWith("homepage.") }
                c.labels.putAll(labels)
                c.id = freshId()   // recreated, like the real thing
                c.startedAt = System.currentTimeMillis()
            }
        }
    }
}

object DemoData {
    private fun hex(n: Int) = "%012x".format(0xa11ce0000000L + n * 0x101)

    private fun c(n: Int, project: String?, service: String, image: String, ports: String = "", cpu: Double = 0.3, mem: Double = 60.0,
                  health: String = "none", state: String = "running", labels: Map<String, String> = emptyMap(), name: String? = null) =
        DemoContainer(hex(n), name ?: if (project == null) service else if (service == project) service else "${project}_$service", image,
            project, service, state, health, ports, cpu, mem, LinkedHashMap(labels))

    private fun hp(href: String, name: String, group: String? = null) =
        buildMap { group?.let { put("homepage.group", it) }; put("homepage.name", name); put("homepage.href", href) }

    fun homelab() = DemoWorld(
        hostname = "homelab", prettyOs = "Ubuntu 24.04.5 LTS", osId = "ubuntu", cores = 4, memTotalKb = 16_300_000,
        diskTotal = 500_000_000_000, diskUsed = 230_000_000_000, ip = "203.0.113.10", tailscaleIp = "100.64.12.7",
        seedUpdates = 5, seedSecurity = 2, seedReboot = true,
        containers = mutableListOf(
            c(1, "dockge", "dockge", "louislam/dockge:1", "0.0.0.0:5001->5001/tcp", 0.1, 154.0, labels = hp("http://dockge.local:5001", "Dockge", "Tools")),
            c(2, "immich", "server", "ghcr.io/immich-app/immich-server:release", "0.0.0.0:2283->2283/tcp", 2.0, 612.0, "healthy", labels = hp("https://immich.tailnet-name.ts.net", "Immich", "Media")),
            c(3, "immich", "machine-learning", "ghcr.io/immich-app/immich-machine-learning:release", "", 1.0, 1100.0, "healthy"),
            c(4, "immich", "postgres", "tensorchord/pgvecto-rs:pg14", "", 0.4, 188.0, "healthy"),
            c(5, "immich", "redis", "redis:7", "", 0.1, 9.0),
            c(6, "aiometadata", "aiometadata", "ghcr.io/example/aiometadata:latest", "127.0.0.1:3100->3100/tcp", 1.0, 285.0, labels = hp("https://aiometadata.example.com", "AIOMetadata", "Media")),
            c(7, "aiometadata", "redis", "redis:7", "", 0.1, 47.0),
            c(8, "monitoring", "cadvisor", "gcr.io/cadvisor/cadvisor:latest", "0.0.0.0:8081->8080/tcp", 6.0, 147.0),
            c(9, "monitoring", "grafana", "grafana/grafana:latest", "0.0.0.0:3000->3000/tcp", 3.0, 226.0, labels = hp("http://grafana.local:3000", "Grafana", "Tools")),
            c(10, "monitoring", "node-exporter", "prom/node-exporter:latest", "", 0.3, 10.0),
            c(11, "monitoring", "prometheus", "prom/prometheus:latest", "0.0.0.0:9090->9090/tcp", 1.0, 228.0),
            c(12, "shlink", "shlink", "shlinkio/shlink:stable", "0.0.0.0:8082->8080/tcp", 0.2, 256.0),
            c(13, "shlink", "db", "postgres:16", "", 0.1, 22.0, name = "shlink_db"),
            c(14, "cloudflared", "cloudflared", "cloudflare/cloudflared:latest", "", 0.0, 23.0, "unhealthy", "restarting").also { it.restarts = 3 },
            c(15, "watchtower", "watchtower", "containrrr/watchtower:latest", "", 0.0, 16.0),
            c(16, "vaultwarden", "vaultwarden", "vaultwarden/server:latest", "127.0.0.1:8083->80/tcp", 0.2, 71.0, "healthy", labels = hp("https://vault.example.com", "Vaultwarden", "Security")),
            c(17, "paperless", "webserver", "ghcr.io/paperless-ngx/paperless-ngx:latest", "0.0.0.0:8000->8000/tcp", 0.8, 520.0, "healthy"),
            c(18, "paperless", "broker", "redis:7", "", 0.1, 12.0),
            c(19, "paperless", "db", "postgres:16", "", 0.2, 64.0),
            c(20, null, "portainer_agent", "portainer/agent:latest", "", 0.0, 30.0),
        ),
    )

    fun garage() = DemoWorld(
        hostname = "garage-nuc", prettyOs = "Debian GNU/Linux 12 (bookworm)", osId = "debian", cores = 2, memTotalKb = 7_900_000,
        diskTotal = 120_000_000_000, diskUsed = 41_000_000_000, ip = "192.168.1.40", tailscaleIp = "",
        seedUpdates = 0, seedSecurity = 0, seedReboot = false,
        containers = mutableListOf(
            c(31, "pihole", "pihole", "pihole/pihole:latest", "0.0.0.0:8053->80/tcp", 0.5, 95.0, "healthy", labels = hp("http://192.168.1.40:8053/admin", "Pi-hole", "Network")),
            c(32, "jellyfin", "jellyfin", "jellyfin/jellyfin:latest", "0.0.0.0:8096->8096/tcp", 1.5, 410.0, labels = hp("http://garage-nuc:8096", "Jellyfin", "Media")),
            c(33, "samba", "samba", "dperson/samba:latest", "0.0.0.0:445->445/tcp", 0.0, 18.0, state = "exited"),
        ),
    )
}
