package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable

/** Mirrors `DockerSnapshot` in spec/models.schema.json. */
@Serializable
data class DockerSnapshot(val containers: List<DockerContainer>) {
    /**
     * Compose stacks grouped by project label, sorted by name. Containers without a project label are collected in one
     * trailing "Standalone" group.
     */
    val stacks: List<DockerStack>
        get() {
            val byProject = LinkedHashMap<String, MutableList<DockerContainer>>()
            val standalone = mutableListOf<DockerContainer>()
            for (c in containers) {
                val p = c.project
                if (p != null) byProject.getOrPut(p) { mutableListOf() } += c else standalone += c
            }
            val result = byProject.keys.sorted().map { name ->
                val members = byProject.getValue(name).sortedBy { it.service ?: it.name }
                // Every container in a project carries the same compose labels. If they disagree (a container made by an older
                // file, a moved directory), there is no single file set to run against, so the stack gets none and compose
                // actions are refused instead of guessing.
                val layouts = members.mapNotNull { c ->
                    val dir = c.workingDir ?: return@mapNotNull null
                    ComposeLayout(dir, c.configFiles.ifEmpty { listOfNotNull(c.configFile) })
                }.toSet()
                val layout = layouts.singleOrNull()
                DockerStack(
                    name = name, workingDir = layout?.workingDir, configFile = layout?.files?.firstOrNull(),
                    configFiles = layout?.files ?: emptyList(), containers = members, isStandalone = false,
                )
            }.toMutableList()
            if (standalone.isNotEmpty()) {
                result += DockerStack("Standalone", null, null, emptyList(), standalone.sortedBy { it.name }, isStandalone = true)
            }
            return result
        }

    private data class ComposeLayout(val workingDir: String, val files: List<String>)
}

@Serializable
data class DockerContainer(
    /** Short container id (12 hex chars), as `docker ps` prints it. */
    val id: String,
    val name: String,
    val image: String,
    /** running, exited, paused, restarting, created, removing, dead */
    val state: String,
    /** none, starting, healthy, unhealthy */
    val health: String,
    /** Docker's own status text, e.g. "Up 3 hours (healthy)". */
    val status: String,
    /** Published ports only (host to container), de-duplicated across IPv4/IPv6 and bind addresses. */
    val ports: List<PortMapping>,
    val project: String? = null,
    val service: String? = null,
    val workingDir: String? = null,
    /** First compose file (for display). */
    val configFile: String? = null,
    /** All compose files, in the order compose merges them (the label is a comma-separated list). */
    val configFiles: List<String> = emptyList(),
    val cpuPercent: Double? = null,
    val memoryUsedBytes: Long? = null,
    val memoryLimitBytes: Long? = null,
    /** From the container's `homepage.*` labels; null when it has no valid `homepage.href`. */
    val bookmark: Bookmark? = null,
) {
    @Serializable
    data class PortMapping(val hostPort: Int, val containerPort: Int, val proto: String)

    val isRunning: Boolean get() = state == "running" || state == "restarting"
    val isUnhealthy: Boolean get() = health == "unhealthy"
}

data class DockerStack(
    val name: String,
    val workingDir: String?,
    val configFile: String?,
    val configFiles: List<String>,
    val containers: List<DockerContainer>,
    val isStandalone: Boolean,
) {
    val id: String get() = name
    val configFileName: String? get() = configFile?.substringAfterLast('/')
    val runningCount: Int get() = containers.count { it.isRunning }
    val unhealthyCount: Int get() = containers.count { it.isUnhealthy }
    val stoppedCount: Int get() = containers.size - runningCount
    /** True when any container of the stack has a bookmark. */
    val hasBookmark: Boolean get() = containers.any { it.bookmark != null }
}

sealed class DockerParseError(message: String) : Exception(message) {
    object NotInstalled : DockerParseError("Docker is not installed on this server.")

    /** Docker is installed but the command failed (daemon down, permission denied...). Carries docker's message. */
    class Daemon(val text: String) : DockerParseError(text)

    class Malformed(val detail: String) : DockerParseError("Unexpected docker output: $detail")
}
