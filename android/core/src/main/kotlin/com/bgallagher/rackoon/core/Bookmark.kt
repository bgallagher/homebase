package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable
import java.net.URI

/**
 * A service's link, stored in the Homepage dashboard's Docker label convention (gethomepage.dev) so the same compose file
 * works with other tools: `homepage.href`, `homepage.name`, `homepage.group`, `homepage.icon`, `homepage.description`.
 * Only `href` is required. Other `homepage.*` labels (widgets, weight...) are neither read nor changed.
 */
@Serializable
data class Bookmark(
    val href: String,
    val name: String? = null,
    val group: String? = null,
    val icon: String? = null,
    val description: String? = null,
) {
    /** The label to show: its name, or the service's. */
    fun title(fallback: String): String = name ?: fallback

    companion object {
        /** The five label keys this convention uses, in the order they are written. */
        val labelKeys = listOf("homepage.group", "homepage.name", "homepage.icon", "homepage.href", "homepage.description")

        /** A bookmark from a container's labels, or null unless `homepage.href` is a usable http(s) URL. */
        fun from(labels: Map<String, String>): Bookmark? {
            val href = labels["homepage.href"]?.trimBlanks()?.takeIf { isValidUrl(it) } ?: return null
            fun value(key: String): String? = labels[key]?.trimBlanks()?.takeIf { it.isNotEmpty() }
            return Bookmark(href, value("homepage.name"), value("homepage.group"), value("homepage.icon"), value("homepage.description"))
        }

        /** An http or https URL with a host and nothing that could break a label or open something else. */
        fun isValidUrl(s: String): Boolean {
            if (s.length > 2048 || s.any { it.isWhitespace() || it.code < 32 }) return false
            val uri = try { URI(s) } catch (_: Exception) { return false }
            val scheme = uri.scheme?.lowercase()
            return (scheme == "http" || scheme == "https") && !uri.host.isNullOrEmpty()
        }
    }
}
