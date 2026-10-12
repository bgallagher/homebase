package com.bgallagher.rackoon.core

/** Line-level helpers for reading the `services:` block of a compose file's text. Mirrors `ComposeInsert`'s helpers in the Swift core. */
internal object ComposeYaml {
    class Block(val start: Int, val end: Int, val inline: Boolean)

    fun trimmed(line: String): String = line.trim { it == ' ' || it == '\t' }
    fun indent(line: String): Int = line.takeWhile { it == ' ' }.length
    fun isContent(line: String): Boolean = trimmed(line).let { it.isNotEmpty() && !it.startsWith("#") }

    fun servicesBlock(lines: List<String>): Block? {
        val start = lines.indexOfFirst { it.startsWith("services:") }
        if (start < 0) return null
        var rest = lines[start].removePrefix("services:")
        rest.indexOf('#').let { if (it >= 0) rest = rest.substring(0, it) }
        val inline = trimmed(rest).isNotEmpty()
        // The block runs to the next top-level key (a non-blank line that starts in column 0 and is not a comment).
        val end = (start + 1 until lines.size).firstOrNull { i ->
            val c = lines[i].firstOrNull() ?: return@firstOrNull false
            c != ' ' && c != '\t' && c != '#'
        } ?: lines.size
        return Block(start, end, inline)
    }

    fun childIndent(lines: List<String>, block: Block): Int? {
        for (i in block.start + 1 until block.end) {
            if (!isContent(lines[i])) continue
            return indent(lines[i])
        }
        return null
    }

    fun serviceNames(lines: List<String>, block: Block, step: Int): List<String> {
        if (step <= 0) return emptyList()
        return (block.start + 1 until block.end).mapNotNull { i ->
            val line = lines[i]
            if (indent(line) != step) return@mapNotNull null
            val body = line.drop(step)
            val colon = body.indexOf(':')
            val first = body.firstOrNull()
            if (colon < 0 || first == null || first == '#' || first == '-' || first == ' ') return@mapNotNull null
            body.substring(0, colon).trim { it == '"' || it == '\'' }
        }
    }

    fun services(text: String): List<String> {
        val lines = text.replace("\r\n", "\n").split("\n")
        val block = servicesBlock(lines) ?: return emptyList()
        val step = childIndent(lines, block) ?: return emptyList()
        return serviceNames(lines, block, step)
    }
}
