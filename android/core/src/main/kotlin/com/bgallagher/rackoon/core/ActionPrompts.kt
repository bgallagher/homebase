package com.bgallagher.rackoon.core

/** What the confirmation sheet says about an action, and what the Output tab says while it runs. */
data class ActionPrompt(val title: String, val message: String, val working: String, val destructive: Boolean)

/**
 * The words for every container and stack action, and the rule for when they are unavailable. Mirrors `DockerModel` on the
 * Mac, so both apps ask the same question the same way.
 */
object ActionPrompts {
    /** Why the stack's actions are unavailable, or null if they can run. */
    fun blockedReason(stack: DockerStack, readOnly: Boolean, otherActionRunning: Boolean): String? = when {
        readOnly -> "Read-only mode is on"
        otherActionRunning -> "Another stack action is running"
        ComposeAction.UP.command(stack) == null ->
            if (stack.isStandalone) "These containers were not started with Docker Compose" else "No single compose file was found for this stack"
        else -> null
    }

    /**
     * Why a standalone container's actions (pull, restart, delete) are unavailable, or null if they can run. Compose actions
     * stay refused for it ([blockedReason]).
     */
    fun standaloneBlockedReason(stack: DockerStack, readOnly: Boolean, otherActionRunning: Boolean): String? = when {
        readOnly -> "Read-only mode is on"
        otherActionRunning -> "Another stack action is running"
        StandaloneAction.Remove(false).command(stack) == null -> "This container can't be addressed safely"
        else -> null
    }

    /** The question before pulling a standalone container's image, or null when it runs an image that can't be pulled. */
    fun pull(stack: DockerStack): ActionPrompt? {
        val image = StandaloneAction.pullableImage(stack) ?: return null
        return ActionPrompt(
            "Pull the latest $image?",
            "Downloads a newer copy of the image ${stack.name} runs. The container is not touched and keeps running the image it has: " +
                "it was started with docker run, so it only switches when it is created again with its original settings.",
            "Pulling $image…", false,
        )
    }

    /** Stop and restart ask first; start runs straight away (it cannot break anything), so it has no prompt. */
    fun container(action: DockerAction, container: DockerContainer): ActionPrompt? = when (action) {
        DockerAction.START -> null
        DockerAction.STOP -> ActionPrompt("Stop ${container.name}?", "${container.name} will stop until you start it again.", "Stopping ${container.name}…", true)
        DockerAction.RESTART -> ActionPrompt(
            "Restart ${container.name}?", "${container.name} will be restarted. Connections to it drop for a moment.", "Restarting ${container.name}…", false,
        )
    }

    fun stack(action: ComposeAction, stack: DockerStack): ActionPrompt {
        val n = stack.containers.size
        val plural = if (n == 1) "" else "s"
        return when (action) {
            ComposeAction.PULL -> ActionPrompt(
                "Pull images for ${stack.name}?",
                "Downloads newer images for the stack. Running containers are not touched; use Update afterwards to switch to them.",
                "Pulling images for ${stack.name}…", false,
            )
            ComposeAction.UP -> ActionPrompt(
                "Update ${stack.name}?", "Recreates only the containers whose image or settings changed, and starts any that are stopped.",
                "Updating ${stack.name}…", false,
            )
            ComposeAction.RESTART -> ActionPrompt(
                "Restart all $n container$plural in ${stack.name}?",
                "Restarts the containers in place. They are not recreated, so image and settings changes are not applied; use Update for that.",
                "Restarting ${stack.name}…", false,
            )
            ComposeAction.REBUILD -> ActionPrompt(
                "Rebuild ${stack.name}?",
                "Rebuilds images from the stack's Dockerfiles (services with a build section), then recreates the containers that changed. " +
                    "Services that only use pulled images are left alone. Building can take a while.",
                "Rebuilding ${stack.name}…", false,
            )
            ComposeAction.RECREATE -> ActionPrompt(
                "Recreate all $n container$plural in ${stack.name}?",
                "Every container is stopped and recreated from the compose file. Volumes are kept, but anything stored only inside a container is lost.",
                "Recreating ${stack.name}…", true,
            )
        }
    }

    fun rebuild(service: String, stack: DockerStack) = ActionPrompt(
        "Rebuild $service?",
        "Rebuilds the image for $service from its Dockerfile and recreates its container if the image changed. Other services in ${stack.name} " +
            "are left alone. Building can take a while. If $service has no build section, nothing is rebuilt.",
        "Rebuilding $service…", false,
    )

    /** Whether the Rebuild button applies to this container: it needs a compose service the stack can address. */
    fun canRebuild(container: DockerContainer, stack: DockerStack): Boolean =
        container.service?.let { ComposeAction.REBUILD.command(stack, it) != null } ?: false
}
