package com.bgallagher.rackoon.core

/** What the confirm sheet and the Output panel say about one apt action (mirrors the Mac's `UpdatesModel.request`). */
data class AptPrompt(val title: String, val message: String, val workingLabel: String, val outputTitle: String)

/** Pure presentation rules of the Updates screen, kept out of the UI so they are tested and match the Mac's. */
object UpdatesPresentation {
    /** Updates are read from apt's local cache, so lists older than this may be missing newer updates. */
    const val STALE_AFTER_SECONDS = 3L * 86_400

    fun subtitle(s: UpdatesSnapshot): String {
        if (s.packages.isEmpty()) return "Everything is up to date"
        val n = s.packages.size
        val base = "$n update${if (n == 1) "" else "s"} available"
        return if (s.securityCount > 0) "$base, ${s.securityCount} security" else base
    }

    /** "3 days ago", "2 hours ago"... for a time [seconds] in the past. */
    fun relativeAge(seconds: Long): String {
        val s = maxOf(seconds, 0)
        fun unit(n: Long, name: String) = "$n $name${if (n == 1L) "" else "s"} ago"
        return when {
            s < 60 -> "just now"
            s < 3600 -> unit(s / 60, "minute")
            s < 86_400 -> unit(s / 3600, "hour")
            s < 30 * 86_400 -> unit(s / 86_400, "day")
            else -> unit(s / (30 * 86_400), "month")
        }
    }

    /** When the lists were refreshed, as the Mac's tile shows it. */
    fun refreshedText(s: UpdatesSnapshot, nowSeconds: Long): String = s.refreshedAt?.let { relativeAge(nowSeconds - it) } ?: "unknown"

    /** A warning when the package lists are old, else null. */
    fun staleness(s: UpdatesSnapshot, nowSeconds: Long): String? {
        val t = s.refreshedAt ?: return null
        return if (nowSeconds - t > STALE_AFTER_SECONDS) "Package lists were refreshed ${relativeAge(nowSeconds - t)}. Refresh them to see newer updates." else null
    }

    /** Security updates first, then by name. */
    fun sorted(packages: List<PendingUpdate>): List<PendingUpdate> =
        packages.sortedWith(compareBy<PendingUpdate>({ if (it.isSecurity) 0 else 1 }, { it.name }))

    fun securityNames(packages: List<PendingUpdate>): List<String> = sorted(packages).filter { it.isSecurity }.map { it.name }

    /** "Install security updates" needs an explicit list, which is capped; beyond the cap use Install All. */
    fun canInstallSecurity(packages: List<PendingUpdate>): Boolean {
        val n = securityNames(packages).size
        return n > 0 && n <= AptAction.MAX_PACKAGES
    }

    /** Why a button is off, or null when it can be used. */
    fun installSecurityHint(packages: List<PendingUpdate>, readOnly: Boolean): String? = when {
        readOnly -> "Read-only mode is on"
        securityNames(packages).isEmpty() -> "No security updates"
        !canInstallSecurity(packages) -> "Too many to list one by one; use Install All"
        else -> null
    }

    fun prompt(action: AptAction, packageCount: Int, securityCount: Int): AptPrompt = when (action) {
        AptAction.Refresh -> AptPrompt(
            "Refresh package lists?", "Checks the repositories for new versions. Nothing is installed.", "Refreshing package lists…", "apt-get update",
        )
        AptAction.UpgradeAll -> AptPrompt(
            "Install all $packageCount updates?",
            "Held packages stay as they are and existing config files are kept. Some updates may ask for a reboot afterwards.",
            "Installing $packageCount updates…", "apt-get upgrade",
        )
        is AptAction.Upgrade -> {
            val names = action.packages
            AptPrompt(
                "Install $securityCount security update${if (securityCount == 1) "" else "s"}?",
                "Only these packages are upgraded: ${names.take(6).joinToString(", ")}${if (names.size > 6) " and ${names.size - 6} more" else ""}.",
                "Installing security updates…",
                "apt-get install --only-upgrade (${names.size} package${if (names.size == 1) "" else "s"})",
            )
        }
    }
}
