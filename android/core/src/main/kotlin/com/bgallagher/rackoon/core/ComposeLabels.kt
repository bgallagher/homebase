package com.bgallagher.rackoon.core

import com.bgallagher.rackoon.core.ComposeYaml.indent
import com.bgallagher.rackoon.core.ComposeYaml.isContent
import com.bgallagher.rackoon.core.ComposeYaml.trimmed

sealed class ComposeLabelsError(message: String) : Exception(message) {
    class ServiceNotFound(val name: String) : ComposeLabelsError("This compose file has no service called $name.") {
        override fun equals(other: Any?) = other is ServiceNotFound && other.name == name
        override fun hashCode() = name.hashCode()
    }

    object InlineServices : ComposeLabelsError("This file writes services on one line, so labels can't be edited automatically. Edit the file by hand.")

    /** `labels:` is written as `{...}` or `[...]`. */
    class FlowLabels(val name: String) : ComposeLabelsError("The labels of $name are written inline ({...} or [...]), so they can't be edited automatically. Edit the file by hand.") {
        override fun equals(other: Any?) = other is FlowLabels && other.name == name
        override fun hashCode() = name.hashCode()
    }

    /** The service uses a YAML merge key, so its labels may come from an anchor elsewhere. */
    class MergeKey(val name: String) : ComposeLabelsError("$name uses a YAML merge key (<<:), so its labels may come from somewhere else. Edit the file by hand.") {
        override fun equals(other: Any?) = other is MergeKey && other.name == name
        override fun hashCode() = name.hashCode()
    }
}

/** One label to write: its value, or null to remove it. */
data class LabelChange(val key: String, val value: String?)

/**
 * Sets and removes labels on one service of a compose file's text, as line edits only: every other label, comment and line
 * stays exactly as it was. Handles both `- key=value` lists and `key: value` maps, and a service with no labels yet.
 * Mirrors `ComposeLabels` in the Swift core.
 */
object ComposeLabels {
    fun definesService(name: String, text: String): Boolean = name in ComposeYaml.services(text)

    fun setting(changes: List<LabelChange>, name: String, text: String): String {
        val lines = text.split("\n").toMutableList()
        val services = ComposeYaml.servicesBlock(lines) ?: throw ComposeLabelsError.ServiceNotFound(name)
        if (services.inline) throw ComposeLabelsError.InlineServices
        val step = ComposeYaml.childIndent(lines, services)?.takeIf { it > 0 } ?: throw ComposeLabelsError.ServiceNotFound(name)
        val header = (services.start + 1 until services.end).firstOrNull { isServiceHeader(lines[it], name, step) }
            ?: throw ComposeLabelsError.ServiceNotFound(name)

        // The service's own lines: up to the next line at the service level or shallower.
        var end = services.end
        for (i in header + 1 until services.end) if (isContent(lines[i]) && indent(lines[i]) <= step) { end = i; break }
        val keyIndent = (header + 1 until end).firstOrNull { isContent(lines[it]) }?.let { indent(lines[it]) }
            ?: return insertNew(changes, lines, header, step + 2, 2)   // an empty service
        if ((header + 1 until end).any { indent(lines[it]) == keyIndent && trimmed(lines[it]).startsWith("<<:") }) {
            throw ComposeLabelsError.MergeKey(name)
        }
        val unit = maxOf(1, keyIndent - step)
        val labelsLine = (header + 1 until end).firstOrNull { indent(lines[it]) == keyIndent && isKey(lines[it], "labels") }
            ?: return insertNew(changes, lines, lastContentLine(lines, header + 1 until end) ?: header, keyIndent, unit)
        var rest = trimmed(lines[labelsLine]).removePrefix("labels:")
        rest.indexOf('#').let { if (it >= 0) rest = rest.substring(0, it) }
        if (trimmed(rest).isNotEmpty()) throw ComposeLabelsError.FlowLabels(name)

        // The labels block: lines deeper than the `labels:` key. YAML also allows the list's dashes at the key's own indent,
        // so a line at that indent still belongs to the block while it starts with `-`.
        var blockEnd = end
        for (i in labelsLine + 1 until end) {
            if (!isContent(lines[i])) continue
            val d = indent(lines[i])
            if (d < keyIndent || (d == keyIndent && !trimmed(lines[i]).startsWith("-"))) { blockEnd = i; break }
        }
        // Blank lines and comments after the last label belong to whatever follows, not to the labels: leave them alone.
        while (blockEnd - 1 > labelsLine && !isContent(lines[blockEnd - 1])) blockEnd--
        val items = (labelsLine + 1 until blockEnd).filter { isContent(lines[it]) }
        val isList = items.firstOrNull()?.let { trimmed(lines[it]).startsWith("- ") || trimmed(lines[it]) == "-" } ?: true
        val itemIndent = items.firstOrNull()?.let { indent(lines[it]) } ?: (keyIndent + unit)

        for (change in changes) {
            val existing = (labelsLine + 1 until blockEnd).firstOrNull { i ->
                isContent(lines[i]) && indent(lines[i]) == itemIndent && labelKey(lines[i], isList) == change.key
            }
            val newLine = change.value?.let { item(change.key, it, isList, itemIndent) }
            when {
                existing != null && newLine != null -> lines[existing] = newLine
                existing != null -> { lines.removeAt(existing); blockEnd -= 1 }
                newLine != null -> {
                    val at = lastContentLine(lines, labelsLine + 1 until blockEnd) ?: labelsLine
                    lines.add(at + 1, newLine); blockEnd += 1
                }
            }
        }
        // Nothing left under `labels:`: drop the empty key too.
        if ((labelsLine + 1 until blockEnd).none { isContent(lines[it]) }) {
            for (i in blockEnd - 1 downTo labelsLine) lines.removeAt(i)
        }
        return lines.joinToString("\n")
    }

    // MARK: pieces

    private fun insertNew(changes: List<LabelChange>, lines: MutableList<String>, after: Int, keyIndent: Int, unit: Int): String {
        val additions = changes.mapNotNull { c -> c.value?.let { item(c.key, it, true, keyIndent + unit) } }
        if (additions.isEmpty()) return lines.joinToString("\n")
        lines.addAll(after + 1, listOf(" ".repeat(keyIndent) + "labels:") + additions)
        return lines.joinToString("\n")
    }

    private fun item(key: String, value: String, list: Boolean, indent: Int): String {
        val pad = " ".repeat(indent)
        // `$` starts a variable in compose files, so a literal one is written `$$`.
        val v = value.replace("$", "$$")
        return if (list) pad + "- " + scalar("$key=$v") else pad + key + ": " + scalar(v)
    }

    /** A YAML scalar: plain when that is safe, double-quoted otherwise. */
    internal fun scalar(s: String): String {
        val special = "-?:,[]{}#&*!|>'\"%@`"
        fun isNewline(c: Char) = c == '\n' || c == '\r' || c == '\u0085' || c == ' ' || c == ' '
        val needsQuotes = s.isEmpty() || s != trimmed(s) || s.contains(": ") || s.contains(" #") || s.endsWith(":") ||
            s.any { it == '"' || it == '\\' || isNewline(it) } || (special.contains(s.first()) && !s.startsWith("homepage.")) ||
            s.lowercase() in listOf("true", "false", "yes", "no", "on", "off", "null", "~") || s.toDoubleOrNull() != null
        return if (needsQuotes) "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"" else s
    }

    private fun labelKey(line: String, list: Boolean): String? {
        var body = trimmed(line)
        if (list) {
            if (!body.startsWith("-")) return null
            body = unquote(trimmed(body.drop(1)))
            val eq = body.indexOf('=')
            return if (eq >= 0) body.substring(0, eq) else body
        }
        val colon = body.indexOf(':')
        if (colon < 0) return null
        return unquote(trimmed(body.substring(0, colon)))
    }

    private fun unquote(s: String): String {
        if (s.length < 2) return s
        val f = s.first()
        return if (f == s.last() && (f == '"' || f == '\'')) s.substring(1, s.length - 1) else s
    }

    private fun isServiceHeader(line: String, name: String, step: Int): Boolean {
        if (indent(line) != step) return false
        val t = trimmed(line)
        if (!t.startsWith(name)) return false
        var rest = t.drop(name.length)
        if (!rest.startsWith(":")) return false
        rest = rest.drop(1)
        rest.indexOf('#').let { if (it >= 0) rest = rest.substring(0, it) }
        return trimmed(rest).isEmpty()
    }

    private fun isKey(line: String, key: String) = trimmed(line).startsWith("$key:")
    private fun lastContentLine(lines: List<String>, range: IntRange): Int? = range.reversed().firstOrNull { isContent(lines[it]) }
}
