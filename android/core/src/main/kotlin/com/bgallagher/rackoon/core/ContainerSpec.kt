package com.bgallagher.rackoon.core

enum class RestartPolicy(val raw: String, val label: String) {
    NO("no", "No"), ALWAYS("always", "Always"), UNLESS_STOPPED("unless-stopped", "Unless stopped"), ON_FAILURE("on-failure", "On failure"),
}

data class PortRow(val host: String = "", val container: String = "") {
    val isBlank: Boolean get() = host.isEmpty() && container.isEmpty()

    /** The host field is `port`, or `address:port` to publish on one address only (an IPv4 address or `${VAR}`). */
    val bindAddress: String? get() = if (host.contains(':')) host.substringBeforeLast(':') else null
    val hostPort: Int? get() = host.substringAfterLast(':').toIntOrNull()
}

data class VolumeRow(val source: String = "", val target: String = "") {
    val isBlank: Boolean get() = source.isEmpty() && target.isEmpty()
}

data class EnvRow(val key: String = "", val value: String = "") {
    val isBlank: Boolean get() = key.isEmpty() && value.isEmpty()
}

/**
 * What the Add container form describes: one service, written as compose YAML (and `.env` lines for its environment). Blank rows
 * are ignored, so the form can always show an empty row to type into. Mirrors `ContainerSpec` in the Swift core.
 */
data class ContainerSpec(
    val name: String = "",
    val image: String = "",
    val ports: List<PortRow> = listOf(PortRow()),
    val volumes: List<VolumeRow> = listOf(VolumeRow()),
    val env: List<EnvRow> = listOf(EnvRow()),
    val restart: RestartPolicy = RestartPolicy.UNLESS_STOPPED,
) {
    val activePorts: List<PortRow> get() = ports.filter { !it.isBlank }
    val activeVolumes: List<VolumeRow> get() = volumes.filter { !it.isBlank }
    val activeEnv: List<EnvRow> get() = env.filter { !it.isBlank }

    // MARK: problems (each is a short message for the field, null when fine or still empty)

    val nameProblem: String? get() = if (name.isEmpty() || ComposeAction.isServiceName(name)) null else "Use letters, digits, - _ and ."

    val imageProblem: String?
        get() {
            if (image.isEmpty()) return null
            val valid = image.length <= 255 && image.all { it in IMAGE_CHARACTERS } && image.first().let { it.isLetter() || it.isDigit() }
            return if (valid) null else "That doesn't look like an image name, such as nginx:alpine"
        }

    /** The first problem anywhere in the form, or null when it can be turned into YAML. An empty name or image counts. */
    val blockingProblem: String?
        get() {
            if (name.isEmpty()) return "Enter a container name"
            nameProblem?.let { return it }
            if (image.isEmpty()) return "Enter an image"
            imageProblem?.let { return it }
            activePorts.firstNotNullOfOrNull { portProblem(it) }?.let { return it }
            activeVolumes.firstNotNullOfOrNull { volumeProblem(it) }?.let { return it }
            activeEnv.firstNotNullOfOrNull { envProblem(it) }?.let { return it }
            val keys = activeEnv.map { it.key }
            if (keys.toSet().size != keys.size) return "An environment name is used twice"
            return null
        }

    // MARK: output

    /** The service as compose YAML lines. `baseIndent` is the indent of the service name, `step` the indent per level (an existing file may use 4). */
    fun yamlLines(baseIndent: Int = 2, step: Int = 2): List<String> {
        fun pad(level: Int) = " ".repeat(baseIndent + step * level)
        val out = arrayListOf(
            pad(0) + name + ":", pad(1) + "image: " + scalar(image),
            pad(1) + "restart: " + if (restart == RestartPolicy.NO) "\"no\"" else restart.raw,   // bare `no` is a YAML boolean
        )
        if (activePorts.isNotEmpty()) { out += pad(1) + "ports:"; activePorts.forEach { out += pad(2) + "- \"${it.host}:${it.container}\"" } }
        if (activeVolumes.isNotEmpty()) { out += pad(1) + "volumes:"; activeVolumes.forEach { out += pad(2) + "- " + scalar(it.source + ":" + it.target) } }
        if (activeEnv.isNotEmpty()) { out += pad(1) + "environment:"; activeEnv.forEach { out += pad(2) + "${it.key}: \${${it.key}}" } }
        return out
    }

    /** A whole compose file with just this service. */
    val composeText: String get() = (listOf("services:") + yamlLines()).joinToString("\n") + "\n"

    /** `.env` lines for the environment rows. */
    val envText: String get() = activeEnv.joinToString("\n") { EnvMerge.line(it.key, it.value) } + if (activeEnv.isEmpty()) "" else "\n"

    companion object {
        private const val IMAGE_CHARACTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@-"

        fun portProblem(p: PortRow): String? {
            fun valid(n: Int?) = n != null && n in 1..65535
            if (p.isBlank) return null
            if (!valid(p.hostPort) || !valid(p.container.toIntOrNull())) return "Ports are numbers from 1 to 65535"
            p.bindAddress?.let { address ->
                val ipv4 = Regex("""^\d{1,3}(\.\d{1,3}){3}$""").matches(address)
                val variable = Regex("""^\$\{[A-Za-z_][A-Za-z0-9_]*}$""").matches(address)
                if (!ipv4 && !variable) return "Use port, or address:port with an IPv4 address or \${NAME}"
            }
            return null
        }

        fun volumeProblem(v: VolumeRow): String? {
            if (v.isBlank) return null
            val pathLike = v.source.startsWith("./") || v.source.startsWith("/")
            if (!pathLike) return "Use a path such as ./data or /srv/data"
            if (!v.target.startsWith("/")) return "The container path must start with /"
            val text = v.source + v.target
            if (text.any { it == '\n' || it == '\r' || it == '"' || it == '\'' || it == '\\' } || v.source.contains(':') || v.target.contains(':')) {
                return "Paths can't contain quotes, backslashes or colons"
            }
            return null
        }

        fun envProblem(e: EnvRow): String? {
            if (e.isBlank) return null
            val ok = e.key.isNotEmpty() && e.key.all { it.code < 128 && (it.isLetterOrDigit() || it == '_') } && !e.key.first().isDigit()
            if (!ok) return "Names use letters, digits and _ and can't start with a digit"
            if (e.value.any { it == '\n' || it == '\r' }) return "A value must be on one line"
            return null
        }

        internal fun scalar(s: String): String {
            val plain = s.isNotEmpty() && s.all { it in IMAGE_CHARACTERS }
            return if (plain) s else "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        }
    }
}

object EnvMerge {
    private const val PLAIN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@,+=-"

    /** One `KEY=value` line. Values with anything but plain characters are single-quoted (taken literally, no `$` interpolation), or double-quoted when they contain a single quote. */
    internal fun line(key: String, value: String): String {
        if (value.all { it in PLAIN }) return "$key=$value"
        if (!value.contains('\'')) return "$key='$value'"
        return "$key=\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    }

    class Merged(val text: String, val kept: List<String>)

    /** Appends the entries whose names the existing `.env` does not define yet. Nothing already there is changed, so `kept` lists the names left alone. */
    fun merge(existing: String, adding: List<EnvRow>): Merged {
        val defined = existing.split("\n").mapNotNull { raw ->
            var line = raw.trim()
            if (line.startsWith("#")) return@mapNotNull null
            if (line.startsWith("export ")) line = line.drop(7)
            line.indexOf('=').takeIf { it >= 0 }?.let { line.substring(0, it).trim() }
        }.toSet()
        val fresh = adding.filter { it.key !in defined }
        val kept = adding.filter { it.key in defined }.map { it.key }
        if (fresh.isEmpty()) return Merged(existing, kept)
        var text = existing
        if (text.isNotEmpty() && !text.endsWith("\n")) text += "\n"
        text += fresh.joinToString("\n") { line(it.key, it.value) } + "\n"
        return Merged(text, kept)
    }
}

sealed class ComposeInsertError(message: String) : Exception(message) {
    /** `services:` is written inline (`services: {}`), which can't be extended safely by adding lines. */
    object InlineServices : ComposeInsertError("This file writes services on one line, so a container can't be added automatically. Edit the file by hand.")

    class ServiceExists(val name: String) : ComposeInsertError("This stack already has a service called $name.") {
        override fun equals(other: Any?) = other is ServiceExists && other.name == name
        override fun hashCode() = name.hashCode()
    }
}

/** Adds a service to the text of an existing compose file, as new lines at the end of the `services:` block, without touching anything else. */
object ComposeInsert {
    fun services(text: String): List<String> = ComposeYaml.services(text)

    fun adding(spec: ContainerSpec, text: String): String {
        val lines = text.split("\n").toMutableList()
        val block = ComposeYaml.servicesBlock(lines)
        if (block == null) {
            // No services key at all: add one at the end.
            while (lines.lastOrNull() == "") lines.removeAt(lines.size - 1)
            if (lines.isNotEmpty()) lines += ""
            return (lines + "services:" + spec.yamlLines()).joinToString("\n") + "\n"
        }
        if (block.inline) throw ComposeInsertError.InlineServices
        val step = ComposeYaml.childIndent(lines, block) ?: 2
        if (spec.name in ComposeYaml.serviceNames(lines, block, step)) throw ComposeInsertError.ServiceExists(spec.name)
        // After the last real line of the block, so blank lines that separate it from the next key stay where they are.
        val last = (block.start + 1 until block.end).reversed().firstOrNull { lines[it].trim().isNotEmpty() } ?: block.start
        lines.addAll(last + 1, spec.yamlLines(step, step))
        return lines.joinToString("\n")
    }
}
