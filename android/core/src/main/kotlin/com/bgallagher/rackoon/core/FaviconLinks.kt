package com.bgallagher.rackoon.core

import java.net.URI

/**
 * Finds a site's icon in its HTML. Pure, so it is tested on fixtures and portable: the app does the fetching and the image
 * decoding; this only says where to look, best candidate first. Mirrors the Swift `FaviconLinks`.
 */
object FaviconLinks {
    data class Candidate(
        val url: String,
        /** The `rel` tokens, lower-cased (`icon`, `shortcut`, `apple-touch-icon`). */
        val rel: List<String>,
        val type: String?,
        /** The largest dimension declared in `sizes` (0 when unknown or `any`). */
        val size: Int,
    )

    /** The origin of a bookmark URL (`scheme://host[:port]`), the key a favicon is cached under: all bookmarks on one site share its icon. */
    fun origin(href: String): String? {
        if (!Bookmark.isValidUrl(href)) return null
        val uri = runCatching { URI(href.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase() ?: return null
        val defaultPort = if (scheme == "https") 443 else 80
        return if (uri.port == -1 || uri.port == defaultPort) "$scheme://$host" else "$scheme://$host:${uri.port}"
    }

    /** `/favicon.ico` on the same origin, the last thing to try. */
    fun defaultIcon(origin: String): String = "$origin/favicon.ico"

    /**
     * Icon links in [html], resolved against [base] (the page's final URL), best first, at most [limit]. Only http(s) and
     * nothing from `<link>`s that are not icons (`mask-icon` and stylesheets are skipped).
     */
    fun candidates(html: String, base: String, limit: Int = 5): List<Candidate> {
        val baseUri = runCatching { URI(base) }.getOrNull() ?: return emptyList()
        val found = mutableListOf<Candidate>()
        for (m in linkTag.findAll(html)) {
            val attrs = attributes(m.value)
            val rel = (attrs["rel"] ?: "").lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
            if (!(rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")) || rel.contains("mask-icon")) continue
            val href = attrs["href"]?.trim()?.takeIf { it.isNotEmpty() } ?: continue
            val url = runCatching { baseUri.resolve(href.replace(" ", "%20")) }.getOrNull() ?: continue
            val scheme = url.scheme?.lowercase()
            if ((scheme != "http" && scheme != "https") || url.host == null) continue
            found += Candidate(url.toString(), rel, attrs["type"]?.lowercase(), largest(attrs["sizes"]))
        }
        // sortedByDescending is stable, so ties keep page order.
        return found.sortedByDescending { score(it) }.distinctBy { it.url }.take(limit)
    }

    /** apple-touch-icons (usually 180 px PNGs) first, then PNG-like icons, then SVG, then .ico; larger before smaller up to 256. */
    internal fun score(c: Candidate): Int {
        val path = runCatching { URI(c.url).path }.getOrNull()?.lowercase() ?: ""
        val type = c.type ?: ""
        val kind = when {
            c.rel.any { it.startsWith("apple-touch-icon") } -> 4
            type.contains("svg") || path.endsWith(".svg") -> 2
            type.contains("icon") || path.endsWith(".ico") -> 1
            else -> 3
        }
        return kind * 1000 + minOf(c.size, 256)
    }

    private fun largest(sizes: String?): Int =
        (sizes ?: "").lowercase().split(Regex("\\s+")).mapNotNull { part ->
            val dims = part.split("x").mapNotNull { it.toIntOrNull() }
            if (part.count { it == 'x' } == 1 && dims.size == 2) maxOf(dims[0], dims[1]) else null
        }.maxOrNull() ?: 0

    private val linkTag = Regex("<link\\b[^>]*>", RegexOption.IGNORE_CASE)
    private val attribute = Regex("""([a-zA-Z][\w:-]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))""")

    /** `name="value"`, `name='value'` and `name=value` pairs of one tag, names lower-cased; the first of a repeated name wins. */
    internal fun attributes(tag: String): Map<String, String> {
        val out = linkedMapOf<String, String>()
        for (m in attribute.findAll(tag)) {
            val value = listOf(3, 4, 5).firstNotNullOfOrNull { i -> m.groups[i]?.value } ?: ""
            out.putIfAbsent(m.groupValues[1].lowercase(), value.replace("&amp;", "&"))
        }
        return out
    }
}
