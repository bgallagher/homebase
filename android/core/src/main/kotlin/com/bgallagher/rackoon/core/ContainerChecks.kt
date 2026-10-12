package com.bgallagher.rackoon.core

enum class ImageStatus {
    FOUND,

    /** The registry has no such image or tag, or it needs a login this server doesn't have. */
    NOT_FOUND,
    TIMED_OUT,
}

/** The read-only checks behind the Add container page, run on the server: does the image exist, which ports are already listening (spec `image_exists`, `listening_ports`). */
object ContainerChecks {
    val listeningPortsCommand: String get() = SpecCommands.script("listening_ports")

    fun imageCommand(image: String): String? {
        val spec = ContainerSpec(name = "x", image = image)
        if (image.isEmpty() || spec.imageProblem != null) return null
        val quoted = ShellQuote.quote(image) ?: return null
        return Template.fill(SpecCommands.script("image_exists"), mapOf("image" to quoted))
    }

    fun parseImageStatus(output: String): ImageStatus = when (output.trim()) {
        "found" -> ImageStatus.FOUND
        "timeout" -> ImageStatus.TIMED_OUT
        else -> ImageStatus.NOT_FOUND
    }

    /** Ports in `ss -H -tln` output: the local address is the fourth column, and the port follows its last colon (`0.0.0.0:80`, `[::]:80`, `127.0.0.53%lo:53`). */
    fun parseListeningPorts(output: String): Set<Int> {
        val ports = HashSet<Int>()
        for (line in output.split("\n")) {
            val columns = line.split(' ', '\t').filter { it.isNotEmpty() }
            if (columns.size < 4) continue
            val local = columns[3]
            val colon = local.lastIndexOf(':').takeIf { it >= 0 } ?: continue
            local.substring(colon + 1).toIntOrNull()?.let { ports += it }
        }
        return ports
    }

    /** "Docker Hub" for images with no registry host in the name, otherwise the host (`ghcr.io`). */
    fun registryName(image: String): String {
        val parts = image.split('/')
        val first = parts.firstOrNull() ?: return "Docker Hub"
        return if (parts.size > 1 && (first.contains('.') || first.contains(':') || first == "localhost")) first else "Docker Hub"
    }

    // MARK: checklist rows (the four from the design: YAML, image, ports, container name)

    fun imageRow(spec: ContainerSpec, status: ImageStatus?): EditorCheckRow {
        if (spec.imageProblem != null || spec.image.isEmpty()) return EditorCheckRow("image", EditorCheckRow.State.SKIPPED, "Image", spec.imageProblem ?: "Enter an image")
        return when (status) {
            null -> EditorCheckRow("image", EditorCheckRow.State.RUNNING, "Image", "Looking for ${spec.image}…")
            ImageStatus.FOUND -> EditorCheckRow("image", EditorCheckRow.State.PASS, "Image", "${spec.image} found on ${registryName(spec.image)}")
            ImageStatus.NOT_FOUND -> EditorCheckRow("image", EditorCheckRow.State.FAIL, "Image", "${spec.image} not found on ${registryName(spec.image)}, or it needs a login")
            ImageStatus.TIMED_OUT -> EditorCheckRow("image", EditorCheckRow.State.WARN, "Image", "The registry didn't answer in time, so ${spec.image} is unchecked")
        }
    }

    /**
     * One row per published host port. A port counts as taken if something listens on it on the server (which covers Docker's own
     * published ports); the owner is named when a known container publishes it.
     */
    fun portRows(spec: ContainerSpec, listening: Set<Int>?, containers: List<DockerContainer>, serverName: String): List<EditorCheckRow> {
        val wanted = spec.activePorts.mapNotNull { row -> if (ContainerSpec.portProblem(row) == null) row.hostPort else null }
        val rows = ArrayList<EditorCheckRow>()
        val seen = HashSet<Int>()
        for (port in wanted) {
            if (!seen.add(port)) continue
            if (listening == null) {
                rows += EditorCheckRow("port$port", EditorCheckRow.State.RUNNING, "Port $port", "Checking $serverName…")
                continue
            }
            if (wanted.count { it == port } > 1) {
                rows += EditorCheckRow("port$port", EditorCheckRow.State.FAIL, "Port $port is used twice", "Two mappings publish it")
            } else if (port in listening) {
                val owner = containers.firstOrNull { c -> c.ports.any { it.hostPort == port } }
                val by = owner?.let { c -> "By ${c.service ?: c.name}" + (c.project?.let { " in $it" } ?: "") + "." } ?: "Something on $serverName is already listening on it."
                val free = (port + 1..minOf(port + 200, 65535)).firstOrNull { it !in listening && it !in wanted }
                rows += EditorCheckRow("port$port", EditorCheckRow.State.FAIL, "Port $port is already in use", by + (free?.let { " Try $it." } ?: ""))
            } else {
                rows += EditorCheckRow("port$port", EditorCheckRow.State.PASS, "Port $port", "Free on $serverName")
            }
        }
        return rows
    }

    /** The container's name must not clash with a container that exists: compose names it `<stack>-<service>-1`. */
    fun nameRow(spec: ContainerSpec, stack: String?, containers: List<DockerContainer>): EditorCheckRow {
        if (spec.name.isEmpty() || spec.nameProblem != null) return EditorCheckRow("name", EditorCheckRow.State.SKIPPED, "Container name", spec.nameProblem ?: "Enter a name")
        val taken = arrayListOf(spec.name)
        if (!stack.isNullOrEmpty()) taken += "$stack-${spec.name}-1"
        containers.firstOrNull { it.name in taken }?.let { return EditorCheckRow("name", EditorCheckRow.State.FAIL, "Container name", "A container named ${it.name} already exists") }
        return EditorCheckRow("name", EditorCheckRow.State.PASS, "Container name", "${spec.name} is free")
    }

    /** The compose result as one row in the common case: a single "YAML syntax" line when all is well, and the specific failing row (syntax, schema or config) otherwise. */
    fun composeRow(rows: List<EditorCheckRow>, serverName: String): List<EditorCheckRow> {
        if (rows.any { it.state == EditorCheckRow.State.RUNNING }) {
            return listOf(EditorCheckRow("yaml", EditorCheckRow.State.RUNNING, "YAML syntax", "Checking on $serverName…"))
        }
        if (rows.all { it.state == EditorCheckRow.State.PASS || it.state == EditorCheckRow.State.WARN }) {
            return listOf(EditorCheckRow("yaml", EditorCheckRow.State.PASS, "YAML syntax", "Valid, and resolves cleanly on $serverName")) + rows.filter { it.state == EditorCheckRow.State.WARN }
        }
        return rows.filter { it.state == EditorCheckRow.State.FAIL || it.state == EditorCheckRow.State.WARN }
    }
}

/** Runs the server-side lookups. Failures are not errors here: an unreachable server shows up as an unchecked row. */
class ContainerChecker(private val transport: SSHTransport) {
    suspend fun imageStatus(image: String): ImageStatus? {
        val command = ContainerChecks.imageCommand(image) ?: return null
        val result = try { transport.run(command, 30_000) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { return null }
        return if (result.exitCode == 0) ContainerChecks.parseImageStatus(result.stdout) else null
    }

    suspend fun listeningPorts(): Set<Int>? {
        val result = try { transport.run(ContainerChecks.listeningPortsCommand, 10_000) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { return null }
        return if (result.exitCode == 0) ContainerChecks.parseListeningPorts(result.stdout) else null
    }
}
