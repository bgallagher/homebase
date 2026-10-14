package com.bgallagher.rackoon.core

/**
 * App-level actions for a standalone container (one started with `docker run`, not Docker Compose), the counterparts of a
 * compose stack's Pull and Delete. Restart, stop and start are the container's own [DockerAction]s. Mirrors the Swift core;
 * the command texts come from spec/commands.json (`docker_pull_image`, `docker_remove`).
 *
 * Update, Rebuild and Recreate have no counterpart: they recreate the container from its definition, and for a container
 * started with `docker run` there is none to recreate it from (only the original command line had it), so Rackoon refuses
 * them instead of guessing the settings back from `docker inspect`.
 */
sealed class StandaloneAction {
    /** `docker pull <image>`: downloads a newer image. The running container keeps the image it was created from. */
    object PullImage : StandaloneAction()

    /**
     * `docker rm -f [-v] <id>`: stops and removes the container; with `volumes`, also its anonymous volumes. Named volumes,
     * bind-mounted folders and the image are never removed.
     */
    data class Remove(val volumes: Boolean) : StandaloneAction()

    val timeoutMillis: Long
        get() = when (this) {
            PullImage -> 900_000
            is Remove -> 60_000
        }

    /** The exact command, or null if the stack is not one standalone container or a value is unsafe to send. */
    fun command(stack: DockerStack): String? {
        val container = stack.containers.singleOrNull()
        if (!stack.isStandalone || container == null) return null
        return when (this) {
            PullImage -> {
                val quoted = pullableImage(stack)?.let { ShellQuote.quote(it) } ?: return null
                Template.fill(SpecCommands.script(PULL_COMMAND_ID), mapOf("image" to quoted))
            }
            is Remove -> {
                if (!DockerSession.isContainerID(container.id)) return null
                Template.fill(SpecCommands.script(REMOVE_COMMAND_ID), mapOf("volumes" to if (volumes) " -v" else "", "id" to container.id))
            }
        }
    }

    fun intent(stack: DockerStack): Intent? {
        val command = command(stack) ?: return null
        val summary = when (this) {
            PullImage -> "Pull the image of ${stack.name}"
            is Remove -> "Delete container ${stack.name}" + if (volumes) " and its anonymous volumes" else ""
        }
        return Intent(summary, command, Risk.MUTATE)
    }

    companion object {
        internal const val PULL_COMMAND_ID = "docker_pull_image"
        internal const val REMOVE_COMMAND_ID = "docker_remove"

        /** Why a compose-only action can't be offered for a standalone container, for the disabled menu item. */
        const val NEEDS_COMPOSE_REASON = "Not available: this container was started with docker run, so there is no compose file to recreate it from"

        /**
         * The image reference a standalone stack's container runs, if `docker pull` can fetch it again: an image name such as
         * `nginx`, `ghcr.io/org/app:1.2` or `app@sha256:…`. Null for an image id (an image that lost its tag shows as one) and
         * for anything with characters no image reference has, since the value comes from the server and goes back into a shell.
         */
        fun pullableImage(stack: DockerStack): String? {
            if (!stack.isStandalone) return null
            val image = stack.containers.singleOrNull()?.image ?: return null
            return image.takeIf { isImageReference(it) }
        }

        internal fun isImageReference(image: String): Boolean {
            if (image.isEmpty() || image.length > 512 || image.startsWith("sha256:")) return false
            fun Char.isAsciiAlnum() = this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
            if (!image.first().isAsciiAlnum()) return false
            if (!image.all { it.isAsciiAlnum() || it in "._-/:@" }) return false
            // A bare image id (12 or 64 hex characters) is not something a registry serves.
            val hex = image.all { it in '0'..'9' || it in 'a'..'f' }
            return !(hex && (image.length == 12 || image.length == 64))
        }
    }
}
