package com.bgallagher.rackoon.ui

import java.util.Locale

/** Number formatting for the Overview, like the Mac app: decimal units, one decimal for small values. */
object Format {
    fun bytes(value: Long): String {
        val units = listOf("B", "KB", "MB", "GB", "TB")
        var v = value.toDouble()
        var i = 0
        while (v >= 1000 && i < units.lastIndex) { v /= 1000; i++ }
        return if (i == 0) "${value} B" else if (v >= 100) String.format(Locale.US, "%.0f %s", v, units[i]) else String.format(Locale.US, "%.1f %s", v, units[i])
    }

    fun percent(fraction: Double): String = "${(fraction * 100).toInt().coerceIn(0, 100)}%"

    /** "41 days, 6 hours", "3 hours, 12 minutes", "5 minutes". */
    fun uptime(seconds: Double): String {
        val s = seconds.toLong()
        val days = s / 86_400
        val hours = (s % 86_400) / 3_600
        val minutes = (s % 3_600) / 60
        fun unit(n: Long, name: String) = "$n $name${if (n == 1L) "" else "s"}"
        return when {
            days > 0 -> "${unit(days, "day")}, ${unit(hours, "hour")}"
            hours > 0 -> "${unit(hours, "hour")}, ${unit(minutes, "minute")}"
            else -> unit(minutes, "minute")
        }
    }

    /** "just now", "5 min ago", "3 hours ago", "2 days ago" for a time in epoch milliseconds. */
    fun ago(thenMillis: Long, nowMillis: Long = System.currentTimeMillis()): String {
        val s = ((nowMillis - thenMillis) / 1000).coerceAtLeast(0)
        return when {
            s < 45 -> "just now"
            s < 3_600 -> "${(s / 60).coerceAtLeast(1)} min ago"
            s < 86_400 -> "${s / 3_600} ${if (s / 3_600 == 1L) "hour" else "hours"} ago"
            else -> "${s / 86_400} ${if (s / 86_400 == 1L) "day" else "days"} ago"
        }
    }
}
