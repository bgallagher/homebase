package com.bgallagher.rackoon.core

/** One line of the checklist under the editor. */
data class EditorCheckRow(val id: String, val state: State, val title: String, val detail: String) {
    enum class State { PASS, FAIL, WARN, SKIPPED, RUNNING }
}

/**
 * Turns what is known about a draft (local checks, the server's validation of the exact current text) into the checklist from
 * the design: YAML syntax, Compose schema, docker compose config (or .env syntax, then the compose check). Mirrors the Swift core.
 */
object EditorChecks {
    fun rows(
        isEnv: Boolean, serverName: String, local: List<ComposeIssue>, checkError: String?,
        validation: ValidationResult?, validatedText: String?, text: String,
    ): List<EditorCheckRow> {
        val rows = ArrayList<EditorCheckRow>()
        fun row(id: String, state: EditorCheckRow.State, title: String, detail: String) { rows += EditorCheckRow(id, state, title, detail) }

        if (isEnv) {
            local.firstOrNull()?.let { first ->
                return listOf(
                    EditorCheckRow("syntax", EditorCheckRow.State.FAIL, ".env syntax", describe(first)),
                    EditorCheckRow("config", EditorCheckRow.State.SKIPPED, "docker compose config", "Skipped until the syntax is fixed"),
                )
            }
            row("syntax", EditorCheckRow.State.PASS, ".env syntax", "Valid")
        }
        if (checkError != null) {
            row("check", EditorCheckRow.State.FAIL, "Could not check on $serverName", checkError)
            return rows
        }
        // A result for older text must never read as the verdict on this text.
        if (validation == null || validatedText != text) {
            row("running", EditorCheckRow.State.RUNNING, "Checking on $serverName…", "")
            return rows
        }

        val errors = validation.errors
        if (isEnv) {
            val first = errors.firstOrNull()
            if (first != null) row("config", EditorCheckRow.State.FAIL, "docker compose config", describe(first))
            else row("config", EditorCheckRow.State.PASS, "docker compose config", "Resolves cleanly on $serverName")
        } else {
            val syntax = errors.filter(::isSyntax)
            val schema = errors.filter { !isSyntax(it) && isSchema(it) }
            val config = errors.filter { !isSyntax(it) && !isSchema(it) }
            if (syntax.isNotEmpty()) {
                row("syntax", EditorCheckRow.State.FAIL, "YAML syntax", describe(syntax.first()))
                row("schema", EditorCheckRow.State.SKIPPED, "Compose schema", "Skipped until the syntax is fixed")
                row("config", EditorCheckRow.State.SKIPPED, "docker compose config", "Skipped")
            } else {
                row("syntax", EditorCheckRow.State.PASS, "YAML syntax", "Valid")
                if (schema.isNotEmpty()) {
                    row("schema", EditorCheckRow.State.FAIL, "Compose schema", describe(schema.first()))
                    row("config", EditorCheckRow.State.SKIPPED, "docker compose config", "Skipped")
                } else {
                    row("schema", EditorCheckRow.State.PASS, "Compose schema", "All keys recognised")
                    if (config.isNotEmpty()) row("config", EditorCheckRow.State.FAIL, "docker compose config", describe(config.first()))
                    else row("config", EditorCheckRow.State.PASS, "docker compose config", "Resolves cleanly on $serverName")
                }
            }
        }
        validation.warnings.forEachIndexed { i, w -> row("warn$i", EditorCheckRow.State.WARN, "Warning", w.message) }
        return rows
    }

    fun describe(issue: ComposeIssue): String = issue.line?.let { "Line $it: ${issue.message}" } ?: issue.message

    // Not just any mention of "yaml": a schema message names the file ("validating compose.yaml: ...").
    private fun isSyntax(i: ComposeIssue): Boolean {
        val m = i.message.lowercase()
        return i.line != null || m.startsWith("yaml:") || m.contains("go-yaml") || m.contains("failed to parse")
    }

    private fun isSchema(i: ComposeIssue): Boolean {
        val m = i.message.lowercase()
        return m.contains("validating") || m.contains("schema") || m.contains("additional property")
    }
}

/**
 * Names of the `${VARIABLES}` compose says are not set (`The "DB_PASSWORD" variable is not set. Defaulting to a blank string.`), in
 * the order reported, each once. A file that needs them fails (or misbehaves) until they have values.
 */
val ValidationResult.unsetVariables: List<String>
    get() {
        val seen = LinkedHashSet<String>()
        for (issue in issues) {
            val open = issue.message.indexOf("The \"").takeIf { it >= 0 } ?: continue
            val close = issue.message.indexOf("\" variable is not set").takeIf { it >= 0 } ?: continue
            if (open + 5 > close) continue
            val name = issue.message.substring(open + 5, close)
            if (Regex("^[A-Za-z_][A-Za-z0-9_]*$").matches(name)) seen += name
        }
        return seen.toList()
    }
