package com.bgallagher.rackoon.core

enum class HighlightKind { IP_ADDRESS, ERROR, WARNING, SUCCESS }

/** A highlighted stretch of text, as UTF-8 byte offsets into the text that was scanned. */
data class HighlightSpan(val start: Int, val end: Int, val kind: HighlightKind)

/**
 * Finds things worth colouring in plain terminal output: IP addresses, error/warning/success words and high percentages.
 * Conservative on purpose: only whole words, only unambiguous patterns.
 */
object OutputHighlighter {
    // (?U): Unicode-aware \w, \b and \d, like the ICU regex engine the Swift version uses.
    private const val OCTET = """(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"""
    private val ipv4 = Regex("""(?U)(?<![\w.])$OCTET(?:\.$OCTET){3}(?![\w]|\.\d)""")
    private val ipv6Candidate = Regex("""(?U)(?<![\w:.])[0-9A-Fa-f:]{3,}(?![\w:])""")
    private val errorWords = Regex("""(?Ui)\b(?:error|failed|failure|fatal|denied|refused|critical|panic)\b""")
    private val warningWords = Regex("""(?Ui)\b(?:warning|warn)\b""")
    private val successWords = Regex("""(?Ui)\b(?:success|successful|successfully|passed)\b""")
    private val percent = Regex("""(?U)(?<![\w.])(\d{1,3})(?:\.\d+)?%""")

    fun spans(text: String): List<HighlightSpan> {
        // UTF-16 index -> UTF-8 byte offset, computed once.
        val offsets = IntArray(text.length + 1)
        var i = 0
        var bytes = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            val n = Character.charCount(cp)
            val len = when { cp < 0x80 -> 1; cp < 0x800 -> 2; cp < 0x10000 -> 3; else -> 4 }
            for (k in 0 until n) offsets[i + k] = bytes
            bytes += len
            i += n
        }
        offsets[text.length] = bytes

        val found = mutableListOf<HighlightSpan>()
        fun add(re: Regex, kind: (MatchResult) -> HighlightKind?) {
            for (m in re.findAll(text)) {
                val k = kind(m) ?: continue
                found += HighlightSpan(offsets[m.range.first], offsets[m.range.last + 1], k)
            }
        }
        add(ipv4) { HighlightKind.IP_ADDRESS }
        add(ipv6Candidate) { m -> if (isIPv6(m.value)) HighlightKind.IP_ADDRESS else null }
        add(errorWords) { HighlightKind.ERROR }
        add(warningWords) { HighlightKind.WARNING }
        add(successWords) { HighlightKind.SUCCESS }
        add(percent) { m ->
            val v = m.groupValues[1].toIntOrNull() ?: return@add null
            if (v >= 90) HighlightKind.ERROR else if (v >= 75) HighlightKind.WARNING else null // the span is the whole "91%"
        }
        return resolve(found)
    }

    /** Sorted, non-overlapping: when two spans overlap the earlier one wins, and for a tie the first found. */
    internal fun resolve(spans: List<HighlightSpan>): List<HighlightSpan> {
        val result = mutableListOf<HighlightSpan>()
        for (s in spans.sortedWith(compareBy({ it.start }, { it.end }))) {
            val last = result.lastOrNull()
            if (last != null && s.start < last.end) continue
            result += s
        }
        return result
    }

    /**
     * A real IPv6 address: well-formed, and written with `::` or all 8 groups, so times (11:26:02) and MAC addresses
     * (aa:bb:cc:dd:ee:ff) are never mistaken for one.
     */
    internal fun isIPv6(s: String): Boolean {
        if (!s.contains(':')) return false
        val compressed = s.contains("::")
        if (!compressed && s.count { it == ':' } != 7) return false
        if (s.indexOf("::") != s.lastIndexOf("::")) return false // at most one "::"
        val parts = s.split("::")
        fun groups(p: String): List<String>? = if (p.isEmpty()) emptyList() else p.split(':').takeIf { g -> g.all { it.length in 1..4 && it.all { c -> c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F' } } }
        if (!compressed) return groups(s)?.size == 8
        val left = groups(parts[0]) ?: return false
        val right = groups(parts[1]) ?: return false
        return left.size + right.size <= 7
    }
}
