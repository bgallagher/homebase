package com.bgallagher.rackoon.core

/** Quoting for values we interpolate into commands that run in the server's shell. */
object ShellQuote {
    /**
     * Single-quotes the value, so the shell treats it as one literal word. Embedded quotes become `'\''`.
     * Returns null for values no shell word can safely carry (empty, NUL or newline).
     */
    fun quote(value: String): String? {
        if (value.isEmpty() || value.contains('\u0000') || value.contains('\n') || value.contains('\r')) return null
        return "'" + value.replace("'", "'\\''") + "'"
    }

    /** An absolute path, quoted. Relative paths are refused so a command never depends on the login directory. */
    fun quotePath(path: String): String? = if (path.startsWith("/")) quote(path) else null
}

/**
 * Fills `{name}` placeholders in a command template in ONE pass. Inserted values are never rescanned, so a value that
 * happens to contain `{something}` cannot be substituted again (which sequential replacement would do).
 */
internal object Template {
    fun fill(template: String, values: Map<String, String>): String {
        val out = StringBuilder()
        var i = 0
        while (i < template.length) {
            if (template[i] == '{') {
                val close = template.indexOf('}', i)
                if (close >= 0) {
                    val value = values[template.substring(i + 1, close)]
                    if (value != null) {
                        out.append(value)
                        i = close + 1
                        continue
                    }
                }
            }
            out.append(template[i])
            i++
        }
        return out.toString()
    }
}
