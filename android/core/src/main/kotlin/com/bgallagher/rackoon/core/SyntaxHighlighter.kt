package com.bgallagher.rackoon.core

enum class SyntaxKind { KEY, STRING, NUMBER, KEYWORD, COMMENT, PUNCTUATION }

/** A coloured span. `start` and `length` are UTF-16 offsets into the whole text (what Compose's `AnnotatedString` uses). */
data class SyntaxToken(val start: Int, val length: Int, val kind: SyntaxKind)

/** Small line-based tokenizers for compose YAML and `.env` files. They colour; they do not validate (the server does). */
object SyntaxHighlighter {
    fun yaml(text: String): List<SyntaxToken> = scan(text, ::yamlLine)
    fun env(text: String): List<SyntaxToken> = scan(text, ::envLine)

    private fun scan(text: String, line: (String, Int, MutableList<SyntaxToken>) -> Unit): List<SyntaxToken> {
        val tokens = ArrayList<SyntaxToken>()
        var offset = 0
        for (raw in text.split("\n")) {
            // The \r of a CRLF line is not coloured.
            line(if (raw.endsWith("\r")) raw.dropLast(1) else raw, offset, tokens)
            offset += raw.length + 1
        }
        return tokens
    }

    private const val SPACE = ' '
    private const val HASH = '#'
    private const val COLON = ':'
    private const val DASH = '-'

    // MARK: YAML

    private fun yamlLine(u: String, base: Int, out: MutableList<SyntaxToken>) {
        val n = u.length
        var i = 0
        while (i < n && u[i] == SPACE) i++
        if (i >= n) return
        if (u[i] == HASH) { out += SyntaxToken(base + i, n - i, SyntaxKind.COMMENT); return }
        // list markers: "- ", possibly nested
        while (i < n && u[i] == DASH && (i + 1 == n || u[i + 1] == SPACE)) {
            out += SyntaxToken(base + i, 1, SyntaxKind.PUNCTUATION)
            i++
            while (i < n && u[i] == SPACE) i++
        }
        if (i >= n) return
        // key: text up to a ":" followed by a space or end, outside quotes and before any comment
        var j = i
        var quote = '\u0000'
        var valueStart = i
        while (j < n) {
            val c = u[j]
            if (quote != '\u0000') { if (c == quote) quote = '\u0000' }
            else if ((c == '"' || c == '\'') && j == i) quote = c
            else if (c == HASH && (j == i || u[j - 1] == SPACE)) break
            else if (c == COLON && (j + 1 == n || u[j + 1] == SPACE)) {
                if (j > i) {
                    out += SyntaxToken(base + i, j - i, SyntaxKind.KEY)
                    out += SyntaxToken(base + j, 1, SyntaxKind.PUNCTUATION)
                    valueStart = j + 1
                }
                break
            }
            j++
        }
        yamlValue(u, valueStart, base, out)
    }

    private fun yamlValue(u: String, start: Int, base: Int, out: MutableList<SyntaxToken>) {
        val n = u.length
        var i = start
        while (i < n) {
            val c = u[i]
            if (c == SPACE) { i++; continue }
            if (c == HASH && (i == 0 || u[i - 1] == SPACE)) { out += SyntaxToken(base + i, n - i, SyntaxKind.COMMENT); return }
            if (c == '"' || c == '\'') {
                var k = i + 1
                while (k < n && u[k] != c) { if (u[k] == '\\' && c == '"') k++; k++ }   // backslash escapes in "..."
                val end = minOf(n, k + 1)
                out += SyntaxToken(base + i, end - i, SyntaxKind.STRING)
                i = end
                continue
            }
            var k = i
            while (k < n && u[k] != SPACE) k++
            plainKind(u.substring(i, k))?.let { out += SyntaxToken(base + i, k - i, it) }
            i = k
        }
    }

    private fun plainKind(word: String): SyntaxKind? {
        if (word.lowercase() in listOf("true", "false", "yes", "no", "on", "off", "null", "~")) return SyntaxKind.KEYWORD
        if (word.startsWith("$")) return SyntaxKind.KEYWORD
        if (word.first() in '0'..'9' && word.all { it in '0'..'9' || it in ".:/_-" }) return SyntaxKind.NUMBER
        return null
    }

    // MARK: .env

    private fun envLine(u: String, base: Int, out: MutableList<SyntaxToken>) {
        val n = u.length
        var i = 0
        while (i < n && u[i] == SPACE) i++
        if (i >= n) return
        if (u[i] == HASH) { out += SyntaxToken(base + i, n - i, SyntaxKind.COMMENT); return }
        if (n - i > 7 && u.substring(i, i + 7) == "export ") {
            out += SyntaxToken(base + i, 6, SyntaxKind.PUNCTUATION)
            i += 7
            while (i < n && u[i] == SPACE) i++
        }
        val eq = u.indexOf('=', i).takeIf { it >= 0 } ?: return
        if (eq > i) out += SyntaxToken(base + i, eq - i, SyntaxKind.KEY)
        out += SyntaxToken(base + eq, 1, SyntaxKind.PUNCTUATION)
        var v = eq + 1
        if (v >= n) return
        if (u[v] == '"' || u[v] == '\'') {
            val q = u[v]
            var k = v + 1
            while (k < n && u[k] != q) k++
            val end = minOf(n, k + 1)
            out += SyntaxToken(base + v, end - v, SyntaxKind.STRING)
            v = end
            while (v < n && u[v] == SPACE) v++
            if (v < n && u[v] == HASH) out += SyntaxToken(base + v, n - v, SyntaxKind.COMMENT)
            return
        }
        var end = n
        var k = v
        while (k < n) { if (u[k] == HASH && k > v && u[k - 1] == SPACE) { end = k; break }; k++ }
        var trimmed = end
        while (trimmed > v && u[trimmed - 1] == SPACE) trimmed--
        if (trimmed > v) out += SyntaxToken(base + v, trimmed - v, SyntaxKind.STRING)
        if (end < n) out += SyntaxToken(base + end, n - end, SyntaxKind.COMMENT)
    }
}

/** A quick local check of `.env` syntax, so a typo shows immediately without a round trip. The server's check still has the final say. */
object EnvSyntax {
    /** The variable names a .env text defines (`NAME=value` and `export NAME=value` lines; comments and odd lines skipped). */
    fun names(text: String): List<String> = text.split("\n").mapNotNull { raw ->
        var line = raw.trim()
        if (line.isEmpty() || line.startsWith("#")) return@mapNotNull null
        if (line.startsWith("export ")) line = line.drop(7).trim()
        val eq = line.indexOf('=').takeIf { it >= 0 } ?: return@mapNotNull null
        line.substring(0, eq).trim().ifEmpty { null }
    }

    fun check(text: String): List<ComposeIssue> {
        val issues = ArrayList<ComposeIssue>()
        text.split("\n").forEachIndexed { index, raw ->
            var line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            if (line.startsWith("export ")) line = line.drop(7).trim()
            val eq = line.indexOf('=')
            fun error(message: String) { issues += ComposeIssue(ComposeIssue.Severity.ERROR, index + 1, message) }
            if (eq < 0) { error("Expected NAME=value"); return@forEachIndexed }
            val name = line.substring(0, eq).trim()
            when {
                name.isEmpty() -> error("Missing variable name before =")
                name.contains(' ') || name.contains('\t') -> error("Variable names cannot contain spaces")
                !name.all { it.code < 128 && (it.isLetterOrDigit() || it in "_.-") } || name.first().isDigit() -> error("Invalid variable name \"$name\"")
            }
        }
        return issues
    }
}
