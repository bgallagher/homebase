package com.bgallagher.rackoon.core

/**
 * What can be done to a discovered systemd service. Mirrors ServiceActions.swift. Each action is built as a [LibraryCommand],
 * so it runs exactly like a Commands-tab entry: reads stream straight away, changes (`start`/`stop`/`restart`) show a read-only
 * status first and then the standard confirmation, are refused in Read-only mode, and system units go through `sudo -n`. A
 * user unit (`systemctl --user`) needs no sudo.
 *
 * Processes started by hand have no actions: nothing on the server knows how to start one again.
 */
enum class ServiceAction(val raw: String, val title: String) {
    START("start", "Start"),
    STOP("stop", "Stop"),
    RESTART("restart", "Restart"),
    STATUS("status", "Status"),
    LOGS("logs", "Recent Logs");

    val isMutating: Boolean get() = this == START || this == STOP || this == RESTART

    /** Whether the action makes sense for a service in this state. */
    fun appliesTo(service: DiscoveredService): Boolean = when (this) {
        START -> service.status == DiscoveredService.Status.STOPPED || service.status == DiscoveredService.Status.FAILED
        STOP -> service.status != DiscoveredService.Status.STOPPED && service.status != DiscoveredService.Status.FAILED
        RESTART -> service.status != DiscoveredService.Status.STOPPING
        STATUS, LOGS -> true
    }
}

object ServiceActions {
    /** The groups a user is in that can read the system journal without sudo (root can anyway). */
    private const val JOURNAL_READER = """[ "${'$'}(id -u)" -eq 0 ] || id -nG | tr ' ' '\n' | grep -qxE 'adm|systemd-journal|wheel'"""

    /**
     * A unit name that is safe to hand to systemctl (it is quoted as well): letters, digits and `:_.@-\`, ending in `.service`,
     * not starting with `-` (an option).
     */
    fun isUnitName(name: String): Boolean {
        if (!name.endsWith(".service") || name.startsWith("-") || name.length > 256) return false
        return name.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in ":_.@-\\" }
    }

    /** The command for `action` on `service`, or null for a process or a name that is not safe. */
    fun command(action: ServiceAction, service: DiscoveredService): LibraryCommand? {
        val unit = service.unit ?: return null
        if (!isUnitName(unit)) return null
        val q = ShellQuote.quote(unit) ?: return null
        val user = service.kind == DiscoveredService.Kind.USER
        val userFlag = if (user) " --user" else ""
        val ctl = if (user) "systemctl --user" else "\$S systemctl"
        val id = "service.${action.raw}.${service.id}"
        val title = "${action.title} ${service.name}"
        val status = "systemctl$userFlag status --no-pager --lines=5 $q 2>&1 | head -n 20; true"
        return when (action) {
            ServiceAction.START, ServiceAction.STOP, ServiceAction.RESTART -> LibraryCommand(
                id = id, title = title, group = "Services",
                summary = summary(action, service),
                script = "$ctl ${action.raw} $q && echo \"Now: \$(systemctl$userFlag is-active $q)\"",
                risk = Risk.MUTATE, root = !user, preview = status,
                warning = if (action == ServiceAction.START) null else warning(service),
            )
            ServiceAction.STATUS -> LibraryCommand(
                id = id, title = title, group = "Services", summary = "What systemd says about $unit now.",
                script = "systemctl$userFlag status --no-pager --lines=30 $q; true",
            )
            ServiceAction.LOGS -> {
                val script = if (user) "journalctl --user -u $q -n 200 --no-pager"
                else "if $JOURNAL_READER; then journalctl -u $q -n 200 --no-pager; else \$S journalctl -u $q -n 200 --no-pager; fi"
                LibraryCommand(
                    id = id, title = title, group = "Services", summary = "The last 200 lines $unit wrote to the journal.",
                    script = script, root = !user,
                )
            }
        }
    }

    /** Follows the unit's journal in a terminal tab. For a system unit the user can't read, `sudo` asks in the terminal. */
    fun followLogsCommand(service: DiscoveredService): String? {
        val unit = service.unit ?: return null
        if (!isUnitName(unit)) return null
        val q = ShellQuote.quote(unit) ?: return null
        if (service.kind == DiscoveredService.Kind.USER) return "journalctl --user -u $q -f -n 100"
        return "if $JOURNAL_READER; then journalctl -u $q -f -n 100; else sudo journalctl -u $q -f -n 100; fi"
    }

    internal fun summary(action: ServiceAction, service: DiscoveredService): String {
        val unit = service.unit ?: service.name
        val how = if (service.kind == DiscoveredService.Kind.USER) "with systemctl --user (your own service, no sudo)" else "with systemctl (needs sudo)"
        return when (action) {
            ServiceAction.START -> "Starts $unit $how."
            ServiceAction.STOP -> "Stops $unit $how. It starts again at the next boot if it is enabled."
            else -> "Stops and starts $unit $how."
        }
    }

    /** What stopping this one costs, for the products where that is not obvious. */
    internal fun warning(service: DiscoveredService): String? = when (service.product) {
        "tailscale" -> "If you reach this server over Tailscale, the connection drops until it is back (Rackoon included)."
        "ssh" -> "Rackoon talks to this server over ssh. Open sessions usually survive, but new ones are refused while it is down."
        "docker" -> "Every container on this server stops with it."
        "wireguard", "netbird", "zerotier", "openvpn", "cloudflared" -> "Anything reaching this server through it loses access until it is back."
        else -> null
    }
}
