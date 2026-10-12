package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/** A value a library command asks for before it runs (a container to look at, a host to check). */
@Serializable
data class LibraryParam(val id: String, val label: String, val kind: Kind, val placeholder: String = "") {
    @Serializable
    enum class Kind {
        @kotlinx.serialization.SerialName("container") CONTAINER,
        @kotlinx.serialization.SerialName("hostname") HOSTNAME,
    }

    /** The value shell-quoted, or null if it is not a valid value of this kind. Nothing else ever reaches the shell. */
    fun quoted(value: String): String? {
        val v = value.trimBlanks()
        when (kind) {
            Kind.CONTAINER -> {
                // A container name or id: letters, digits, `_`, `.`, `-`, starting with a letter or digit.
                if (v.isEmpty() || v.length > 128 || !(v.first().isAsciiLetterOrDigit()) ||
                    !v.all { it.isAsciiLetterOrDigit() || it == '_' || it == '.' || it == '-' }) return null
            }
            Kind.HOSTNAME -> {
                if (v.isEmpty() || v.length > 253 || v.startsWith("-") || v.startsWith(".") || v.endsWith(".") || v.endsWith("-") ||
                    v.contains("..") || !v.all { it.isAsciiLetterOrDigit() || it == '-' || it == '.' }) return null
            }
        }
        return ShellQuote.quote(v)
    }

    private fun Char.isAsciiLetterOrDigit() = this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
}

/**
 * One entry of the Commands tab's library, as defined in spec/command-library.json (the only copy). `risk == READ` runs
 * straight away; `MUTATE` shows a preview (the output of `preview`, a read-only dry run) and asks first.
 */
data class LibraryCommand(
    val id: String,
    val title: String,
    val group: String,
    val summary: String,
    /** A shell script; `{param}` placeholders are filled with validated, quoted values and `$S` stands for `sudo -n` (or nothing when the ssh user is root) in entries marked `root`. */
    val script: String,
    val risk: Risk = Risk.READ,
    val root: Boolean = false,
    /** A program the script needs (`docker`, `tailscale`...). Without it the script prints "X is not installed" and stops. */
    val needs: String? = null,
    /** A read-only dry run whose output is shown in the confirmation sheet (mutating entries). */
    val preview: String? = null,
    /** Extra caution shown in the confirmation sheet. */
    val warning: String? = null,
    val params: List<LibraryParam> = emptyList(),
    /** Endless or interactive: opened in a terminal instead of streamed into the output panel. */
    val interactive: Boolean = false,
) {
    val isMutating: Boolean get() = risk == Risk.MUTATE

    /** The runnable script (or preview script) with its guards, or null if a parameter is missing or invalid. */
    fun fullScript(body: String? = null, params: Map<String, String> = emptyMap()): String? {
        val filled = HashMap<String, String>()
        for (p in this.params) filled[p.id] = p.quoted(params[p.id] ?: "") ?: return null
        // A non-root ssh command gets a minimal PATH on Debian, without the sbin directories (ufw, swapon, fail2ban-client...),
        // so a "not installed" answer would be wrong. `sudo -n` has its own secure_path.
        val out = StringBuilder("""PATH="${'$'}PATH:/usr/local/sbin:/usr/sbin:/sbin"; export PATH; """)
        if (root) out.append("""if [ "${'$'}(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; """)
        if (needs != null) out.append("command -v $needs >/dev/null 2>&1 || { echo '$needs is not installed on this server.'; exit 0; }; ")
        return out.toString() + Template.fill(body ?: script, filled)
    }
}

object CommandLibrary {
    private val json = Json { ignoreUnknownKeys = false }

    private class Loaded(val groups: List<String>, val all: List<LibraryCommand>)

    private val loaded: Loaded by lazy {
        val text = CommandLibrary::class.java.getResourceAsStream("/spec/command-library.json")?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: error("spec/command-library.json is missing from the module resources")
        val root = json.parseToJsonElement(text) as JsonObject
        val groups = (root["groups"] as kotlinx.serialization.json.JsonArray).map { it.jsonPrimitive.content }
        val commands = (root["commands"] as kotlinx.serialization.json.JsonArray).map { e ->
            val o = e as JsonObject
            fun str(k: String) = o[k]?.jsonPrimitive?.content
            fun flag(k: String) = o[k]?.jsonPrimitive?.content == "true"
            LibraryCommand(
                id = str("id")!!, title = str("title")!!, group = str("group")!!, summary = str("summary")!!, script = str("script")!!,
                risk = if (str("risk") == "mutate") Risk.MUTATE else Risk.READ, root = flag("root"), needs = str("needs"),
                preview = str("preview"), warning = str("warning"), interactive = flag("interactive"),
                params = (o["params"] as? kotlinx.serialization.json.JsonArray)?.map { json.decodeFromJsonElement(LibraryParam.serializer(), it) } ?: emptyList(),
            )
        }
        Loaded(groups, commands)
    }

    val groups: List<String> get() = loaded.groups
    val all: List<LibraryCommand> get() = loaded.all
    fun commands(group: String): List<LibraryCommand> = all.filter { it.group == group }
}

/**
 * Builds intents for library and custom commands and runs them with live output. Reading runs straight away; anything that
 * changes the server needs a [Confirmation] for exactly that command, checked again here.
 */
class CommandLibrarySession(private val transport: SSHTransport, private val policy: ActionPolicy = ActionPolicy()) {
    /**
     * The intent for a library entry. `preview` is the dry-run output the user saw (part of the intent, so a confirmation only
     * matches what was shown).
     */
    fun intent(command: LibraryCommand, params: Map<String, String> = emptyMap(), preview: String? = null): Intent? {
        val script = command.fullScript(params = params) ?: return null
        return Intent(command.title, script, command.risk, preview)
    }

    /** Anything typed by hand. It can't be classified, so it counts as a change and always needs a confirmation. */
    fun customIntent(text: String): Intent? {
        val t = text.trim()
        if (t.isEmpty() || t.length > 4000 || t.contains('\u0000')) return null
        return Intent("Run a custom command", t, Risk.MUTATE)
    }

    fun confirm(intent: Intent): Confirmation = policy.confirm(intent)

    /** Runs the dry-run script of a mutating entry (read-only) and returns its text, for the confirmation sheet. */
    suspend fun preview(command: LibraryCommand, params: Map<String, String> = emptyMap()): String {
        val body = command.preview ?: return ""
        val script = command.fullScript(body, params) ?: return ""
        val result = try {
            transport.run(script, 30_000)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            return "Could not read the preview from the server."
        }
        return listOf(result.stdout, result.stderr).joinToString("\n").trim()
    }

    /** Runs `intent` with live output. Returns null without running if it needs a confirmation it does not have. */
    suspend fun run(intent: Intent, confirmation: Confirmation?, cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit): StreamedRun? {
        try {
            policy.authorize(intent, confirmation)
        } catch (e: PolicyError) {
            onEvent(ActionStreamEvent.Output("\u001B[31m${e.message}\u001B[0m\r\n"))
            onEvent(ActionStreamEvent.Finished(null))
            return null
        }
        return StreamRunner.run(transport, intent.command, cols, rows, onEvent)
    }
}
