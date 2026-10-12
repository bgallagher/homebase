package com.bgallagher.rackoon.core

/**
 * Deleting a stack: `docker compose down --remove-orphans` (stops and removes its containers and the networks compose made for
 * it), and optionally its named volumes and its folder on the server. Images are never removed. Mirrors the Swift core.
 *
 * The folder step is the dangerous one, so it has its own rules: the folder must not be a system or home directory, every compose
 * file of the stack must live inside it, it only runs after `down` succeeded, and only if the stack's own compose file is still
 * there (so a wrong folder is never emptied). Both command texts come from spec/commands.json (`compose_down`, `compose_down_folder`).
 */
data class StackRemoval(
    /** Also remove the named volumes the compose file declares (`down -v`). Data in them is lost. */
    val removeVolumes: Boolean = false,
    /** Also delete the stack's folder: compose files, .env and everything else in it, including bind-mounted data. */
    val deleteFolder: Boolean = false,
) {
    /** True when anything beyond the containers and networks is removed, which is when the UI asks for the name. */
    val losesData: Boolean get() = removeVolumes || deleteFolder

    /** The exact command, or null if the stack has no usable compose project or paths, or the folder step is not allowed. */
    fun command(stack: DockerStack): String? {
        var folder = ""
        if (deleteFolder) {
            if (folderProblem(stack) != null) return null
            val dir = stack.workingDir?.let { ShellQuote.quotePath(it) } ?: return null
            val file = composeFiles(stack).firstOrNull()?.let { ShellQuote.quotePath(it) } ?: return null
            folder = Template.fill(SpecCommands.script("compose_down_folder"), mapOf("file" to file, "dir" to dir))
        }
        return ComposeAction.fill(SpecCommands.script("compose_down"), stack, mapOf("volumes" to if (removeVolumes) " -v" else "", "folder" to folder))
    }

    fun intent(stack: DockerStack): Intent? {
        val command = command(stack) ?: return null
        val what = if (deleteFolder) "Delete stack ${stack.name} and its folder" else "Delete stack ${stack.name}"
        return Intent(what, command, Risk.MUTATE)
    }

    companion object {
        const val TIMEOUT_MILLIS = 600_000L

        /** The compose files of a stack, in the same order the compose actions use them. */
        internal fun composeFiles(stack: DockerStack): List<String> = stack.configFiles.ifEmpty { listOfNotNull(stack.configFile) }

        /** Why the stack's folder can't be offered for deletion, or null when it can. */
        fun folderProblem(stack: DockerStack): String? {
            val dir = stack.workingDir?.takeIf { it.startsWith("/") } ?: return "The stack's folder is unknown"
            unsafeFolderReason(dir)?.let { return it }
            val files = composeFiles(stack)
            val inside = files.all { it.startsWith("$dir/") && isNormal(it) }
            if (files.isEmpty() || !inside) return "The compose files are not all inside that folder"
            return null
        }

        /** No empty, `.` or `..` parts, no doubled or trailing slashes. */
        internal fun isNormal(path: String): Boolean {
            if (!path.startsWith("/") || path.contains("//") || (path.endsWith("/") && path != "/")) return false
            return path.split('/').none { it == ".." || it == "." }
        }

        /** System trees where nothing of a stack's belongs, and whole mount points and home folders. */
        private val systemTrees = listOf(
            "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/boot", "/dev", "/proc", "/sys", "/etc", "/run", "/snap", "/var/lib/docker", "/var/lib/containerd",
        )
        private val protectedFolders = setOf(
            "/", "/home", "/root", "/opt", "/srv", "/mnt", "/media", "/tmp", "/var", "/data", "/Users",
            "/var/lib", "/var/log", "/var/tmp", "/var/www", "/var/opt", "/var/run", "/var/cache",
        )

        internal fun unsafeFolderReason(path: String): String? {
            if (!isNormal(path)) return "That folder path is not in a normal form"
            val parts = path.split('/').filter { it.isNotEmpty() }
            if (parts.size < 2) return "$path is too high up to delete"
            if (systemTrees.any { path == it || path.startsWith("$it/") }) return "$path is a system folder"
            if (path in protectedFolders) return "$path is a system folder"
            // /home/<user>, /Users/<user>, and the top level of a mount point (/mnt/<disk>, /media/<disk>).
            if (parts.size == 2 && parts[0] in listOf("home", "Users", "mnt", "media")) return "$path is a home folder or a mount point"
            return null
        }
    }
}
