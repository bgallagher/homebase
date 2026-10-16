package com.bgallagher.rackoon.core

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Service discovery: what runs on a server outside Docker. Mirrors Services.swift. One read-only command (spec `services`)
// lists every loaded systemd service (the system's and the ssh user's own `--user` ones), the listening TCP sockets and, for
// each listening process, its command line and cgroup. The cgroup ties a port to its unit, and tells a process started by hand
// (in a login session, like `npx paperclipai`) from one a unit runs. Containers are left to the Docker screen.
//
// `ServicesParser.scan` reads the text as it is; `ServicesParser.parse` turns it into the services a person cares about
// (`ServiceDiscovery`), named from `ServiceCatalog` and with OS plumbing (dbus, getty, udev...) hidden by default.

// The raw reading

/** One systemd service unit as `systemctl show` reports it. */
data class SystemdUnit(
    /** The unit's full name, `tailscaled.service` or `code-server@alice.service`. */
    val name: String,
    val description: String = "",
    val loadState: String = "",
    /** active, reloading, inactive, failed, activating, deactivating. */
    val activeState: String = "",
    /** running, exited, dead, failed, auto-restart, ... */
    val subState: String = "",
    /** success, exit-code, signal, core-dump, timeout, ... */
    val result: String = "",
    /** enabled, disabled, static, indirect, generated, ... */
    val unitFileState: String = "",
    val fragmentPath: String = "",
    /** simple, forking, oneshot, notify, ... */
    val type: String = "",
    val mainPID: Int? = null,
    /** When it last became active, in microseconds since boot (compare with the uptime). */
    val activeEnterMonotonic: Long? = null,
    val memoryBytes: Long? = null,
    val restarts: Int? = null,
)

/** A listening TCP socket from `ss -H -tlnp`. Processes are only known for the ssh user's own (all of them for root). */
data class ListeningSocket(val address: String, val port: Int, val processes: List<Owner>) {
    /** A process holding it: its `comm` name and pid, in the order ss lists them. */
    data class Owner(val name: String, val pid: Int)
}

/** A listening process: its command line (NULs as spaces, cut at 300 bytes) and its cgroup path. */
data class ListeningProcess(val pid: Int, val commandLine: String, val cgroup: String)

data class ServicesScan(
    val uptime: Double? = null,
    val isRoot: Boolean = false,
    val system: List<SystemdUnit> = emptyList(),
    val user: List<SystemdUnit> = emptyList(),
    val sockets: List<ListeningSocket> = emptyList(),
    val processes: List<ListeningProcess> = emptyList(),
)

// What the app shows

/** An address and port a service listens on. */
@Serializable
data class ServicePort(
    /** As ss reports it, without brackets or an interface: `0.0.0.0`, `::`, `*`, `127.0.0.1`, `100.64.0.10`. */
    val address: String,
    val port: Int,
) {
    val isLoopback: Boolean get() = address.startsWith("127.") || address == "::1" || address == "localhost"
    val isWildcard: Boolean get() = address in setOf("0.0.0.0", "::", "*", "")

    val isLikelyWeb: Boolean get() = port !in NON_WEB

    /**
     * The host to open this port on from the phone: the server's preferred address (its Tailscale IP, else its LAN IP) when it
     * listens everywhere, the address itself when it listens on one, null when only the server can reach it.
     */
    fun linkHost(preferred: String?): String? = when {
        isLoopback -> null
        isWildcard -> preferred
        address.contains(':') -> "[$address]"
        else -> address
    }

    /** How reachable it is, for keeping one entry per port: everywhere, then one address, then loopback. */
    internal val reach: Int get() = if (isWildcard) 2 else if (isLoopback) 0 else 1

    companion object {
        /** Ports that are almost never a web page (ssh, DNS, mail, databases, file sharing, VPN, Beszel's agent), so they get no link. */
        internal val NON_WEB: Set<Int> = setOf(
            21, 22, 23, 25, 53, 110, 111, 139, 143, 389, 445, 465, 587, 636, 853, 993, 995, 1194, 1883, 2049,
            3306, 3478, 5353, 5432, 6379, 8883, 11211, 27017, 41641, 45876, 51820,
        )
    }
}

/** A service found on a server: a systemd unit (system or the ssh user's), or a listening process no unit runs. */
@Serializable
data class DiscoveredService(
    /** `system/<unit>`, `user/<unit>` or `process/<name>`: stable across scans, so a choice made for it sticks. */
    val id: String,
    val kind: Kind,
    /** The systemd unit (system and user kinds). */
    val unit: String? = null,
    /** What the tile is titled: the product's name when it is a known one, else the unit or process name. */
    val name: String,
    /** The unit's description, or the process's command line. */
    val detail: String,
    /** The [ServiceCatalog] product it was recognised as. */
    val product: String? = null,
    val status: Status,
    /** systemd's sub state (`running`, `auto-restart`, `dead`...); "running" for a process. */
    val subState: String,
    /** systemd's result when it is not `success` (`exit-code`, `signal`, `core-dump`...). */
    val result: String? = null,
    /** Whether it starts at boot; null when that does not apply (static units, processes). */
    val enabledAtBoot: Boolean? = null,
    /** How long it has been running, in seconds, when known. */
    val activeSeconds: Double? = null,
    val memoryBytes: Long? = null,
    val restarts: Int,
    val ports: List<ServicePort>,
    /** The unit file, or the program a process runs. */
    val path: String? = null,
    /** Part of the operating system rather than something the user set up (dbus, getty, udev...). */
    val isPlumbing: Boolean,
    val visibleByDefault: Boolean,
) {
    @Serializable
    enum class Kind(val raw: String) {
        @SerialName("system") SYSTEM("system"),
        @SerialName("user") USER("user"),
        @SerialName("process") PROCESS("process"),
    }

    @Serializable
    enum class Status {
        @SerialName("running") RUNNING,
        @SerialName("starting") STARTING,
        @SerialName("restarting") RESTARTING,
        @SerialName("stopping") STOPPING,
        @SerialName("stopped") STOPPED,
        @SerialName("failed") FAILED,
    }

    val isProblem: Boolean get() = status == Status.FAILED || status == Status.RESTARTING
    val isRunning: Boolean get() = status == Status.RUNNING

    /** The words a search matches: name, unit, product, description or command, ports. */
    fun matches(query: String): Boolean {
        val words = query.lowercase().splitSpaces()
        if (words.isEmpty()) return true
        val haystack = (listOf(name, unit ?: "", product ?: "", detail, path ?: "") + ports.map { it.port.toString() })
            .joinToString(" ").lowercase()
        return words.all { haystack.contains(it) }
    }
}

@Serializable
data class ServicesSnapshot(
    /** Sorted by name. */
    val services: List<DiscoveredService>,
    /** The ssh user is root, so every process's ports are known (otherwise only the user's own). */
    val isRoot: Boolean,
    /** systemctl answered: Unraid and some containers have no systemd, and only processes are listed there. */
    val hasSystemd: Boolean,
)

// Known products and OS plumbing

/** A product Rackoon recognises by its unit or process name, with a proper name and an icon. */
data class ServiceProduct(
    val id: String,
    val name: String,
    /** An icon name in the icon collections (dashboard-icons or selfh.st); null to guess from the name. */
    val icon: String? = null,
    /** Unit or process base names (lower-case, no `.service`, no `@instance`, `_` written `-`). */
    val names: List<String>,
    val prefixes: List<String> = emptyList(),
    /** Shown only when asked (always-there infrastructure such as ssh and containerd). */
    val hiddenByDefault: Boolean = false,
)

object ServiceCatalog {
    private fun p(id: String, name: String, icon: String? = null, names: List<String>, prefixes: List<String> = emptyList(), hidden: Boolean = false) =
        ServiceProduct(id, name, icon, names, prefixes, hidden)

    val products: List<ServiceProduct> = listOf(
        p("tailscale", "Tailscale", "tailscale", listOf("tailscaled", "tailscale")),
        p("wazuh-agent", "Wazuh agent", "wazuh", listOf("wazuh-agent")),
        p("wazuh-manager", "Wazuh manager", "wazuh", listOf("wazuh-manager")),
        p("wazuh-indexer", "Wazuh indexer", "wazuh", listOf("wazuh-indexer")),
        p("wazuh-dashboard", "Wazuh dashboard", "wazuh", listOf("wazuh-dashboard")),
        p("beszel-agent", "Beszel agent", "beszel", listOf("beszel-agent")),
        p("beszel", "Beszel hub", "beszel", listOf("beszel", "beszel-hub")),
        p("pi-hole", "Pi-hole", "pi-hole", listOf("pihole-ftl", "pihole", "pi-hole")),
        p("hermes-gateway", "Hermes Agent gateway", "hermes", listOf("hermes-gateway")),
        p("hermes", "Hermes Agent", "hermes", listOf("hermes", "hermes-agent")),
        p("paperclip", "Paperclip", names = listOf("paperclip", "paperclipai")),
        p("github-runner", "GitHub Actions runner", "github", listOf("github-runner"), prefixes = listOf("actions.runner.")),
        p("gitlab-runner", "GitLab runner", "gitlab", listOf("gitlab-runner")),
        p("code-server", "code-server", "code-server", listOf("code-server")),
        p("docker", "Docker Engine", "docker", listOf("docker", "dockerd")),
        p("containerd", "containerd", names = listOf("containerd"), hidden = true),
        p("ssh", "OpenSSH server", names = listOf("ssh", "sshd"), hidden = true),
        p("nginx", "nginx", "nginx", listOf("nginx")),
        p("caddy", "Caddy", "caddy", listOf("caddy")),
        p("apache", "Apache HTTP Server", "apache", listOf("apache2", "httpd")),
        p("haproxy", "HAProxy", "haproxy", listOf("haproxy")),
        p("traefik", "Traefik", "traefik", listOf("traefik")),
        p("postgresql", "PostgreSQL", "postgresql", listOf("postgresql", "postgres")),
        p("mysql", "MySQL", "mysql", listOf("mysql", "mysqld")),
        p("mariadb", "MariaDB", "mariadb", listOf("mariadb", "mariadbd")),
        p("redis", "Redis", "redis", listOf("redis-server", "redis")),
        p("mongodb", "MongoDB", "mongodb", listOf("mongod", "mongodb")),
        p("cloudflared", "Cloudflare Tunnel", "cloudflare", listOf("cloudflared")),
        p("wireguard", "WireGuard", "wireguard", listOf("wg-quick", "wireguard")),
        p("openvpn", "OpenVPN", "openvpn", listOf("openvpn-server", "openvpn-client")),
        p("zerotier", "ZeroTier", "zerotier", listOf("zerotier-one")),
        p("netbird", "NetBird", "netbird", listOf("netbird")),
        p("headscale", "Headscale", "headscale", listOf("headscale")),
        p("crowdsec", "CrowdSec", "crowdsec", listOf("crowdsec", "crowdsec-firewall-bouncer")),
        p("fail2ban", "Fail2ban", "fail2ban", listOf("fail2ban")),
        p("netdata", "Netdata", "netdata", listOf("netdata")),
        p("prometheus", "Prometheus", "prometheus", listOf("prometheus")),
        p("node-exporter", "Node exporter", "prometheus", listOf("prometheus-node-exporter", "node-exporter")),
        p("grafana", "Grafana", "grafana", listOf("grafana-server", "grafana")),
        p("loki", "Loki", "loki", listOf("loki")),
        p("promtail", "Promtail", "loki", listOf("promtail")),
        p("uptime-kuma", "Uptime Kuma", "uptime-kuma", listOf("uptime-kuma")),
        p("syncthing", "Syncthing", "syncthing", listOf("syncthing")),
        p("samba", "Samba", names = listOf("smbd", "nmbd", "samba")),
        p("nfs", "NFS server", names = listOf("nfs-server", "nfs-kernel-server")),
        p("jellyfin", "Jellyfin", "jellyfin", listOf("jellyfin")),
        p("plex", "Plex", "plex", listOf("plexmediaserver", "plex-media-server")),
        p("home-assistant", "Home Assistant", "home-assistant", listOf("home-assistant", "homeassistant")),
        p("node-red", "Node-RED", "node-red", listOf("node-red", "nodered")),
        p("mosquitto", "Mosquitto", "mosquitto", listOf("mosquitto")),
        p("ollama", "Ollama", "ollama", listOf("ollama")),
        p("cockpit", "Cockpit", "cockpit", listOf("cockpit")),
        p("webmin", "Webmin", "webmin", listOf("webmin")),
        p("unbound", "Unbound", "unbound", listOf("unbound")),
        p("adguard-home", "AdGuard Home", "adguard-home", listOf("adguardhome", "adguard-home")),
        p("minio", "MinIO", "minio", listOf("minio")),
        p("k3s", "k3s", names = listOf("k3s", "k3s-agent")),
        p("gitea", "Gitea", "gitea", listOf("gitea")),
        p("forgejo", "Forgejo", "forgejo", listOf("forgejo")),
        p("jenkins", "Jenkins", "jenkins", listOf("jenkins")),
        p("vault", "Vault", "vault", listOf("vault")),
        p("consul", "Consul", "consul", listOf("consul")),
        p("nomad", "Nomad", "nomad", listOf("nomad")),
        p("tor", "Tor", "tor", listOf("tor")),
        p("frigate", "Frigate", "frigate", listOf("frigate")),
        p("zigbee2mqtt", "Zigbee2MQTT", "zigbee2mqtt", listOf("zigbee2mqtt")),
        p("ntfy", "ntfy", "ntfy", listOf("ntfy")),
        p("gotify", "Gotify", "gotify", listOf("gotify")),
        p("authelia", "Authelia", "authelia", listOf("authelia")),
        p("restic", "restic", "restic", listOf("restic", "restic-rest-server", "rest-server")),
        p("borg", "Borg", "borg", listOf("borgmatic", "borg")),
    )

    /**
     * The operating system's own services: always there, rarely interesting, hidden by default (still listed under Hidden,
     * and a failed one is always shown).
     */
    internal val plumbing: Set<String> = setOf(
        "dbus", "dbus-broker", "getty", "serial-getty", "user", "user-runtime-dir", "polkit", "udisks2", "upower", "modemmanager",
        "networkmanager", "networkmanager-wait-online", "networkmanager-dispatcher", "networkd-dispatcher", "wpa-supplicant",
        "bluetooth", "avahi-daemon", "cups", "cups-browsed", "rtkit-daemon", "iio-sensor-proxy", "bolt", "fwupd", "thermald",
        "rsyslog", "syslog", "cron", "crond", "anacron", "atd", "chrony", "chronyd", "ntp", "ntpd", "ntpsec", "irqbalance",
        "multipathd", "snapd", "packagekit", "accounts-daemon", "colord", "gdm", "gdm3", "lightdm", "sddm", "display-manager",
        "power-profiles-daemon", "switcheroo-control", "kerneloops", "whoopsie", "apport", "unattended-upgrades", "rpcbind",
        "rpc-statd", "rpc-statd-notify", "open-vm-tools", "vgauth", "qemu-guest-agent", "console-setup", "keyboard-setup",
        "setvtrgb", "apparmor", "ufw", "mdmonitor", "pipewire", "pipewire-pulse", "wireplumber", "filter-chain", "mpris-proxy",
        "haveged", "rngd", "kdump-tools", "sysstat", "netplan-configure", "dracut-shutdown", "alsa-restore", "alsa-state",
        "tuned", "auditd", "mcelog", "acpid", "gpu-manager", "smartmontools", "smartd", "wtmpdb-update-boot", "gpg-agent",
        "ssh-agent", "p11-kit-server", "obex", "speech-dispatcher", "pulseaudio", "rtkit", "low-memory-monitor",
        "blk-availability", "emergency", "rescue", "lxd-agent", "hv-kvp-daemon", "iscsid", "open-iscsi", "finalrd",
    )
    internal val plumbingPrefixes = listOf(
        "systemd-", "plymouth", "getty", "gnome-", "xdg-", "at-spi", "cloud-", "lvm2-", "apt-", "dpkg-",
        "snap.", "ubuntu-", "motd-", "e2scrub", "fstrim", "logrotate", "man-db", "dbus-", "evolution-",
        "tracker-", "gvfs-", "pipewire-", "wireplumber", "grub-", "secureboot-", "esm-",
    )

    /** Listening programs that belong to the system or to Docker, when no unit tells (a server without systemd). */
    internal val plumbingProcesses: Set<String> = setOf(
        "sshd", "systemd-resolve", "systemd-resolved", "cupsd", "avahi-daemon", "rpcbind",
        "chronyd", "docker-proxy", "dockerd", "containerd", "rpc.statd", "dhclient",
    )

    /**
     * Programs that publish a container's ports or run it (Docker, Podman). On a server without systemd their cgroup doesn't
     * say "docker", so they are recognised by name and left to the Docker screen.
     */
    internal val containerHelpers = listOf("docker-proxy", "containerd-shim", "rootlesskit", "rootlessport", "slirp4netns", "conmon")

    internal fun isContainerHelper(name: String): Boolean {
        val n = name.lowercase()
        return containerHelpers.any { n.startsWith(it) }
    }

    /** A unit or process name in the form products are listed by: lower-case, no `.service`, no `@instance`, `_` as `-`. */
    fun baseName(name: String): String {
        var n = name.lowercase().removeSuffix(".service")
        val at = n.indexOf('@')
        if (at >= 0) n = n.substring(0, at)
        return n.replace('_', '-')
    }

    fun product(name: String): ServiceProduct? {
        val base = baseName(name)
        return products.firstOrNull { p -> base in p.names || p.prefixes.any { base.startsWith(it) } }
    }

    fun isPlumbing(name: String): Boolean {
        val base = baseName(name)
        return base in plumbing || plumbingPrefixes.any { base.startsWith(it) }
    }
}

// Parsing

object ServicesParser {
    fun parse(output: String): ServicesSnapshot = ServiceDiscovery.discover(scan(output))

    fun scan(output: String): ServicesScan {
        val sections = OverviewParser.splitSections(output)
        return ServicesScan(
            uptime = sections["uptime"]?.firstOrNull()?.trimBlanks()?.toDoubleOrNull(),
            isRoot = sections["uid"]?.firstOrNull()?.trimBlanks() == "0",
            system = units(sections["system"] ?: emptyList()),
            user = units(sections["user"] ?: emptyList()),
            sockets = (sections["listen"] ?: emptyList()).mapNotNull(::socket),
            processes = (sections["procs"] ?: emptyList()).mapNotNull(::process),
        )
    }

    /** `systemctl show` prints one `Key=value` block per unit, in its own key order; a block starts at `Id=`. */
    internal fun units(lines: List<String>): List<SystemdUnit> {
        val out = mutableListOf<SystemdUnit>()
        var current: SystemdUnit? = null
        for (line in lines) {
            val eq = line.indexOf('=')
            if (eq < 0) continue
            val key = line.substring(0, eq)
            val value = line.substring(eq + 1)
            if (key == "Id") {
                current?.let { out += it }
                current = SystemdUnit(name = value)
                continue
            }
            val c = current ?: continue
            current = when (key) {
                "Description" -> c.copy(description = value)
                "LoadState" -> c.copy(loadState = value)
                "ActiveState" -> c.copy(activeState = value)
                "SubState" -> c.copy(subState = value)
                "Result" -> c.copy(result = value)
                "UnitFileState" -> c.copy(unitFileState = value)
                "FragmentPath" -> c.copy(fragmentPath = value)
                "Type" -> c.copy(type = value)
                "MainPID" -> c.copy(mainPID = value.toIntOrNull()?.takeIf { it > 0 })
                "ActiveEnterTimestampMonotonic" -> c.copy(activeEnterMonotonic = value.toULongOrNull()?.takeIf { it > 0u }?.toLong())
                "NRestarts" -> c.copy(restarts = value.toIntOrNull())
                // "[not set]" without memory accounting; UINT64_MAX ("infinity") on some versions.
                "MemoryCurrent" -> value.toULongOrNull()?.takeIf { it < Long.MAX_VALUE.toULong() }?.let { c.copy(memoryBytes = it.toLong()) } ?: c
                else -> c
            }
        }
        current?.let { out += it }
        return out
    }

    /**
     * `LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1001,fd=6),...)`. The local address is the first
     * `address:port` column; IPv6 comes in brackets and an address may carry `%interface`.
     */
    internal fun socket(line: String): ListeningSocket? {
        val fields = line.split(' ', '\t').filter { it.isNotEmpty() }
        val local = fields.firstOrNull { it.contains(':') && !it.startsWith("users:") } ?: return null
        val colon = local.lastIndexOf(':')
        val port = local.substring(colon + 1).toIntOrNull() ?: return null
        var address = local.substring(0, colon)
        if (address.startsWith("[") && address.endsWith("]") && address.length >= 2) address = address.substring(1, address.length - 1)
        val pct = address.indexOf('%')
        if (pct >= 0) address = address.substring(0, pct)
        val owners = mutableListOf<ListeningSocket.Owner>()
        val users = line.indexOf("users:(")
        if (users >= 0) {
            val rest = line.substring(users + "users:(".length)
            for (part in rest.split("(\"").drop(1)) {
                val endName = part.indexOf('"')
                if (endName < 0) continue
                val name = part.substring(0, endName)
                val pidAt = part.indexOf("pid=")
                if (pidAt < 0) continue
                val digits = part.substring(pidAt + 4).takeWhile { it.isDigit() }
                digits.toIntOrNull()?.let { owners += ListeningSocket.Owner(name, it) }
            }
        }
        return ListeningSocket(address, port, owners)
    }

    /** `<pid>\t<command line>\t<cgroup>`. */
    internal fun process(line: String): ListeningProcess? {
        val parts = line.split('\t')
        if (parts.size < 3) return null
        val pid = parts[0].trimBlanks().toIntOrNull() ?: return null
        return ListeningProcess(pid, parts[1].trimBlanks(), parts[2].trimBlanks())
    }

    /** `cloudflared.service` -> cloudflared (lower-case), "" for null: a description that only repeats it says nothing. */
    fun displayBase(unit: String?): String = unitBase(unit ?: "").lowercase()

    /** `hermes-gateway.service` -> hermes-gateway. */
    internal fun unitBase(unit: String): String = unit.removeSuffix(".service")
}

// From a reading to services

object ServiceDiscovery {
    /** Where a listening process lives, from its cgroup path. */
    sealed class Home {
        object Container : Home() { override fun toString() = "Container" }
        data class SystemUnit(val unit: String) : Home()
        /** A unit of a user's own systemd (`user@1000.service/app.slice/x.service`). */
        data class UserUnit(val unit: String) : Home()
        /** Anything else: a login session (`session-12.scope`), the root cgroup on a server without systemd... */
        data class Loose(val cgroup: String) : Home()
    }

    internal fun home(cgroup: String): Home {
        val lower = cgroup.lowercase()
        if (lower.contains("docker") || lower.contains("containerd") || lower.contains("libpod") || lower.contains("kubepods") ||
            lower.contains("/lxc")
        ) return Home.Container
        val parts = cgroup.split('/').filter { it.isNotEmpty() }
        val unit = parts.lastOrNull { it.endsWith(".service") } ?: return Home.Loose(cgroup)
        // user@1000.service is the user's systemd itself; a unit below it is one of theirs.
        if (unit.startsWith("user@")) return Home.Loose(cgroup)
        val underUser = parts.any { it.startsWith("user@") && it.endsWith(".service") }
        return if (underUser) Home.UserUnit(unit) else Home.SystemUnit(unit)
    }

    /** Interpreters and launchers: the program they run says more than their own name. */
    internal val interpreters = listOf(
        "node", "nodejs", "python", "java", "ruby", "php", "perl", "bun", "deno", "sh", "bash", "dotnet",
        "npm", "npx", "uv", "uvx", "pnpm", "yarn", "mono", "pwsh", "env",
    )

    /** Databases and caches an app starts for itself: grouped with that app when it is the only other thing in its session. */
    internal val helpers: Set<String> = setOf("postgres", "postgresql", "redis-server", "redis", "mysqld", "mariadbd", "mongod", "memcached")

    private val scriptExtensions = listOf(".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".php", ".pl", ".jar", ".sh")

    /** A process's name: its own (`comm`), or for an interpreter the script it runs (`node .../paperclipai` -> paperclipai). */
    internal fun processName(comm: String, commandLine: String): String {
        val name = comm.lowercase().replaceFirst("-mainthread", "")
        val isInterpreter = interpreters.any { i ->
            name == i || (name.startsWith(i) && name.substring(i.length).all { it.isDigit() || it == '.' })
        }
        if (!isInterpreter) return comm
        for (arg in commandLine.splitSpaces().drop(1)) {
            if (arg == "-c" || arg == "-e") break   // inline code: nothing to name it after
            if (arg.startsWith("-")) continue
            var base = lastPathComponent(arg)
            for (ext in scriptExtensions) if (base.endsWith(ext)) base = base.dropLast(ext.length)
            if (base.isNotEmpty() && base != "index" && base != "main" && base != "server") return base
        }
        return comm
    }

    /** Like NSString's lastPathComponent: trailing slashes ignored, "/" stays "/". */
    private fun lastPathComponent(path: String): String {
        val trimmed = path.trimEnd('/')
        if (trimmed.isEmpty()) return if (path.isEmpty()) "" else "/"
        return trimmed.substringAfterLast('/')
    }

    private class LooseEntry(val comm: String) { val ports = mutableListOf<ServicePort>() }

    fun discover(scan: ServicesScan): ServicesSnapshot {
        val processByPID = LinkedHashMap<Int, ListeningProcess>()
        for (p in scan.processes) processByPID.putIfAbsent(p.pid, p)
        // Each socket's ports go to the unit or loose process that holds them.
        val unitPorts = HashMap<String, MutableList<ServicePort>>()        // "system/<unit>" or "user/<unit>"
        val loose = LinkedHashMap<Int, LooseEntry>()
        for (socket in scan.sockets) {
            val port = ServicePort(socket.address, socket.port)
            for (owner in socket.processes) {
                if (ServiceCatalog.isContainerHelper(owner.name)) continue
                val proc = processByPID[owner.pid] ?: continue
                when (val home = home(proc.cgroup)) {
                    Home.Container -> continue
                    is Home.SystemUnit -> unitPorts.getOrPut("system/" + home.unit) { mutableListOf() } += port
                    is Home.UserUnit ->
                        // Another user's unit (seen only as root): listed as a process named after its unit.
                        if (scan.user.any { it.name == home.unit }) {
                            unitPorts.getOrPut("user/" + home.unit) { mutableListOf() } += port
                        } else {
                            loose.getOrPut(owner.pid) { LooseEntry(ServicesParser.unitBase(home.unit)) }.ports += port
                        }
                    is Home.Loose -> loose.getOrPut(owner.pid) { LooseEntry(owner.name) }.ports += port
                }
            }
        }

        val services = mutableListOf<DiscoveredService>()
        for ((kind, units) in listOf(DiscoveredService.Kind.SYSTEM to scan.system, DiscoveredService.Kind.USER to scan.user)) {
            for (unit in units) {
                services += service(unit, kind, scan.uptime, unitPorts["${kind.raw}/${unit.name}"] ?: emptyList()) ?: continue
            }
        }
        services += processes(loose, processByPID)
        services.sortWith(compareBy<DiscoveredService> { it.name.lowercase() }.thenBy { it.id })
        return ServicesSnapshot(services, isRoot = scan.isRoot, hasSystemd = scan.system.isNotEmpty())
    }

    /**
     * One unit as a service, or null when it is not worth listing: not found, masked, a one-shot that ran at boot and is
     * done, or stopped and not meant to start at boot.
     */
    internal fun service(unit: SystemdUnit, kind: DiscoveredService.Kind, uptime: Double?, ports: List<ServicePort>): DiscoveredService? {
        if (unit.loadState != "loaded") return null
        val product = ServiceCatalog.product(unit.name)
        val status = when (unit.activeState) {
            "active", "reloading" -> {
                if (unit.subState == "exited" && product == null) return null
                DiscoveredService.Status.RUNNING
            }
            "activating" -> if (unit.subState == "auto-restart") DiscoveredService.Status.RESTARTING else DiscoveredService.Status.STARTING
            "deactivating" -> DiscoveredService.Status.STOPPING
            "failed" -> DiscoveredService.Status.FAILED
            "inactive" -> {
                if (unit.unitFileState != "enabled" || unit.type == "oneshot") return null
                DiscoveredService.Status.STOPPED
            }
            else -> return null
        }
        val plumbing = ServiceCatalog.isPlumbing(unit.name)
        val entered = unit.activeEnterMonotonic
        val active = if (status == DiscoveredService.Status.RUNNING && uptime != null && entered != null) {
            maxOf(0.0, uptime - entered.toDouble() / 1_000_000)
        } else null
        val enabled = when (unit.unitFileState) {
            "enabled", "enabled-runtime" -> true
            "disabled" -> false
            else -> null
        }
        val visible = when {
            status == DiscoveredService.Status.FAILED || status == DiscoveredService.Status.RESTARTING -> true
            product != null -> !product.hiddenByDefault
            else -> !plumbing
        }
        return DiscoveredService(
            id = "${kind.raw}/${unit.name}", kind = kind, unit = unit.name,
            name = product?.name ?: displayName(unit.name), detail = unit.description, product = product?.id,
            status = status, subState = unit.subState,
            result = if (unit.result.isEmpty() || unit.result == "success") null else unit.result,
            enabledAtBoot = enabled, activeSeconds = active, memoryBytes = unit.memoryBytes, restarts = unit.restarts ?: 0,
            ports = dedupe(ports), path = unit.fragmentPath.ifEmpty { null },
            isPlumbing = plumbing && product == null, visibleByDefault = visible,
        )
    }

    /** `code-server@alice.service` -> "code-server (alice)", `beszel-agent.service` -> "beszel-agent". */
    internal fun displayName(unit: String): String {
        val n = unit.removeSuffix(".service")
        val at = n.indexOf('@')
        if (at < 0) return n
        val instance = n.substring(at + 1)
        return n.substring(0, at) + if (instance.isEmpty()) "" else " ($instance)"
    }

    private data class Found(val pid: Int, val name: String, val proc: ListeningProcess, val ports: List<ServicePort>)

    /**
     * Processes no unit runs. Those in one cgroup (a login session) that are only a database or cache beside one app are folded
     * into that app, so `npx paperclipai` and its own postgres are one service.
     */
    private fun processes(loose: Map<Int, LooseEntry>, byPID: Map<Int, ListeningProcess>): List<DiscoveredService> {
        var found = loose.mapNotNull { (pid, entry) ->
            val proc = byPID[pid] ?: return@mapNotNull null
            Found(pid, processName(entry.comm, proc.commandLine), proc, entry.ports.toList())
        }.toMutableList()
        // Fold helpers into the one app sharing their cgroup.
        val folded = HashSet<Int>()
        for (helper in found.toList()) {
            if (helper.name.lowercase() !in helpers) continue
            val apps = found.indices.filter { found[it].proc.cgroup == helper.proc.cgroup && found[it].name.lowercase() !in helpers }
            if (apps.size == 1 && helper.proc.cgroup != "/") {
                found[apps[0]] = found[apps[0]].copy(ports = found[apps[0]].ports + helper.ports)
                folded += helper.pid
            }
        }
        found.removeAll { it.pid in folded }
        // One program with several processes (nginx's master and workers) is one service.
        val merged = mutableListOf<Found>()
        for (f in found) {
            val i = merged.indexOfFirst { it.name.lowercase() == f.name.lowercase() && it.proc.cgroup == f.proc.cgroup }
            if (i >= 0) {
                val m = merged[i]
                // Named after the parent (the lowest pid, nginx's master), not a worker.
                merged[i] = if (f.pid < m.pid) m.copy(pid = f.pid, proc = f.proc, ports = m.ports + f.ports) else m.copy(ports = m.ports + f.ports)
            } else {
                merged += f
            }
        }
        found = merged

        val used = HashMap<String, Int>()
        return found.map { f ->
            val product = ServiceCatalog.product(f.name)
            val plumbing = f.name.lowercase() in ServiceCatalog.plumbingProcesses
            val ports = dedupe(f.ports)
            var id = "process/" + f.name
            val count = (used[id] ?: 0) + 1
            used[id] = count
            if (count > 1) id += ":" + (ports.firstOrNull()?.port ?: f.pid).toString()
            // Something started by hand in a login session is the user's own; a root-cgroup process on a server without
            // systemd is shown when it is a known product.
            val inSession = f.proc.cgroup.contains("session-") || f.proc.cgroup.contains("user.slice")
            val visible = !plumbing && (product?.let { !it.hiddenByDefault } ?: inSession)
            DiscoveredService(
                id = id, kind = DiscoveredService.Kind.PROCESS, unit = null, name = product?.name ?: f.name, detail = f.proc.commandLine,
                product = product?.id, status = DiscoveredService.Status.RUNNING, subState = "running", result = null, enabledAtBoot = null,
                activeSeconds = null, memoryBytes = null, restarts = 0, ports = ports,
                path = f.proc.commandLine.splitSpaces().firstOrNull(),
                isPlumbing = plumbing, visibleByDefault = visible,
            )
        }
    }

    /** One entry per port, keeping the most reachable address, sorted by port. */
    internal fun dedupe(ports: List<ServicePort>): List<ServicePort> {
        val best = HashMap<Int, ServicePort>()
        for (p in ports) if ((best[p.port]?.reach ?: -1) < p.reach) best[p.port] = p
        return best.values.sortedBy { it.port }
    }
}

// Showing and hiding

/**
 * Which services the user wants to see. Pure: the app keeps it and saves [overrides]. Keys are `<server id>|<service id>` for
 * one server and `*|<service id>` for every server; a server's own choice wins.
 */
class ServiceVisibility(overrides: Map<String, Boolean> = emptyMap()) {
    var overrides: Map<String, Boolean> = overrides.toMap()
        private set

    fun isVisible(service: DiscoveredService, server: String): Boolean =
        overrides[key(server, service.id)] ?: overrides[key(EVERYWHERE, service.id)] ?: service.visibleByDefault

    /** The user chose for this service on this server or everywhere (so "Reset" means something). */
    fun isChosen(service: DiscoveredService, server: String): Boolean =
        overrides[key(server, service.id)] != null || overrides[key(EVERYWHERE, service.id)] != null

    /** The choice made for this service on `server` alone ([EVERYWHERE] for the every-server rule), or null. */
    fun choice(service: String, server: String): Boolean? = overrides[key(server, service)]

    /**
     * `visible` null goes back to the default. `everywhere` also drops each server's own choice for that service, so the new
     * rule is what every server shows.
     */
    fun set(visible: Boolean?, service: String, server: String, everywhere: Boolean = false) {
        val next = overrides.toMutableMap()
        val k = if (everywhere) {
            next.keys.removeAll { it.endsWith("|$service") }
            key(EVERYWHERE, service)
        } else {
            key(server, service)
        }
        if (visible == null) next.remove(k) else next[k] = visible
        overrides = next
    }

    /** A removed server's choices go with it. Returns whether anything changed. */
    fun forget(serverID: String): Boolean {
        val before = overrides.size
        overrides = overrides.filterKeys { !it.startsWith("$serverID|") }
        return overrides.size != before
    }

    override fun equals(other: Any?): Boolean = other is ServiceVisibility && other.overrides == overrides
    override fun hashCode(): Int = overrides.hashCode()

    companion object {
        const val EVERYWHERE = "*"
        fun key(server: String, service: String): String = "$server|$service"
    }
}

// Session

data class ServicesState(
    val snapshot: ServicesSnapshot? = null,
    /** Why the last read failed. The last good snapshot stays beside it. */
    val error: String? = null,
    val updatedAt: Long? = null,
)

/** Reads a server's services on demand. Keeps the last good reading when a read fails. */
class ServicesSession(private val transport: SSHTransport, private val clock: () -> Long = System::currentTimeMillis) {
    companion object {
        val command: String get() = SpecCommands.script("services")
    }

    var state: ServicesState = ServicesState()
        private set

    suspend fun refresh(): ServicesState {
        state = try {
            val result = transport.run(command, timeoutMillis = 15_000)
            // The script ends in `true`, so a non-zero exit is ssh's own failure.
            if (result.exitCode != 0) {
                val detail = result.stderr.trim()
                state.copy(error = detail.ifEmpty { "ssh exited ${result.exitCode}" })
            } else {
                ServicesState(ServicesParser.parse(result.stdout), error = null, updatedAt = clock())
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            state.copy(error = e.message ?: e.toString())
        }
        return state
    }
}
