package com.bgallagher.rackoon.core

/**
 * A line diff (longest common subsequence). Used to highlight changed lines in an editor and to show what a save would change
 * in the confirmation dialog. Mirrors `LineDiff` in the Swift core.
 */
object LineDiff {
    enum class Kind { SAME, ADDED, REMOVED }

    /** `oldNumber`/`newNumber` are 1-based line numbers in the old and new text (null for added / removed lines). */
    data class Line(val kind: Kind, val text: String, val oldNumber: Int?, val newNumber: Int?)

    fun lines(old: String, new: String): List<Line> {
        val a = split(old)
        val b = split(new)
        // Common start and end are the same lines; only the middle needs the table.
        var prefix = 0
        while (prefix < a.size && prefix < b.size && a[prefix] == b[prefix]) prefix++
        var suffix = 0
        while (suffix < a.size - prefix && suffix < b.size - prefix && a[a.size - 1 - suffix] == b[b.size - 1 - suffix]) suffix++
        val am = a.subList(prefix, a.size - suffix)
        val bm = b.subList(prefix, b.size - suffix)

        val middle = ArrayList<Pair<Kind, String>>()
        if (am.size.toLong() * bm.size > 4_000_000L) {
            // Too big for the table: show it as one removal followed by one addition. Correct, just not minimal.
            am.forEach { middle += Kind.REMOVED to it }
            bm.forEach { middle += Kind.ADDED to it }
        } else {
            val n = am.size
            val m = bm.size
            val dp = Array(n + 1) { IntArray(m + 1) }
            for (i in n - 1 downTo 0) for (j in m - 1 downTo 0) {
                dp[i][j] = if (am[i] == bm[j]) dp[i + 1][j + 1] + 1 else maxOf(dp[i + 1][j], dp[i][j + 1])
            }
            var i = 0
            var j = 0
            while (i < n || j < m) {
                when {
                    i < n && j < m && am[i] == bm[j] -> { middle += Kind.SAME to am[i]; i++; j++ }
                    // On a tie the removal comes first, like a normal diff ("- old", "+ new").
                    i < n && (j == m || dp[i + 1][j] >= dp[i][j + 1]) -> { middle += Kind.REMOVED to am[i]; i++ }
                    else -> { middle += Kind.ADDED to bm[j]; j++ }
                }
            }
        }

        val out = ArrayList<Line>(a.size + b.size)
        var oldN = 0
        var newN = 0
        fun same(text: String) { oldN++; newN++; out += Line(Kind.SAME, text, oldN, newN) }
        for (k in 0 until prefix) same(a[k])
        for ((kind, text) in middle) when (kind) {
            Kind.SAME -> same(text)
            Kind.REMOVED -> { oldN++; out += Line(Kind.REMOVED, text, oldN, null) }
            Kind.ADDED -> { newN++; out += Line(Kind.ADDED, text, null, newN) }
        }
        for (k in a.size - suffix until a.size) same(a[k])
        return out
    }

    /** Lines of the new text that were added or changed (1-based). */
    fun changedLineNumbers(old: String, new: String): Set<Int> =
        lines(old, new).mapNotNull { if (it.kind == Kind.ADDED) it.newNumber else null }.toSet()

    /** Number of lines added plus lines removed. */
    fun changeCount(old: String, new: String): Int = lines(old, new).count { it.kind != Kind.SAME }

    /** Changes only, with two lines of context, in a plain +/- form for the confirmation dialog. */
    fun preview(old: String, new: String, context: Int = 2, maxLines: Int = 120): String {
        val all = lines(old, new)
        val changed = all.indices.filter { all[it].kind != Kind.SAME }
        if (changed.isEmpty()) return "No changes."
        val keep = sortedSetOf<Int>()
        for (c in changed) for (k in maxOf(0, c - context)..minOf(all.size - 1, c + context)) keep += k
        var out = ArrayList<String>()
        var last = -2
        for (k in keep) {
            if (k != last + 1 && last >= 0) out += "…"
            val l = all[k]
            val mark = when (l.kind) { Kind.ADDED -> "+"; Kind.REMOVED -> "-"; Kind.SAME -> " " }
            out += "$mark ${l.text}"
            last = k
        }
        if (out.size > maxLines) { val more = out.size - maxLines; out = ArrayList(out.take(maxLines) + "… ($more more lines)") }
        return out.joinToString("\n")
    }

    private fun split(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val parts = text.split("\n").toMutableList()
        if (parts.last() == "") parts.removeAt(parts.size - 1)   // a trailing newline does not make an extra empty line
        return parts
    }
}
