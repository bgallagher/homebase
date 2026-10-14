package com.bgallagher.rackoon.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

enum class DockerAction(val raw: String) {
    START("start"), STOP("stop"), RESTART("restart");

    /** What running this action on a container would do, for the policy and the confirmation sheet. */
    fun intent(containerID: String): Intent? {
        val command = DockerSession.actionCommand(this, containerID) ?: return null
        return Intent("${raw.replaceFirstChar { it.uppercase() }} container $containerID", command, Risk.MUTATE)
    }
}

/** Whole-stack actions, run with `docker compose` from the stack's own compose file. */
enum class ComposeAction(val raw: String, val verb: String, val timeoutMillis: Long) {
    PULL("pull", "Pull images for", 900_000),
    UP("up", "Update", 600_000),
    RESTART("restart", "Restart", 600_000),
    REBUILD("rebuild", "Rebuild", 1_800_000), // building images from source can be slow
    RECREATE("recreate", "Recreate", 600_000);

    private val template: String get() = SpecCommands.script("compose_$raw")

    /**
     * The exact command, or null if the stack has no compose project/paths or any of them is unsafe to send. With `service`,
     * only REBUILD has a command (that one service); every other action is whole-stack.
     */
    fun command(stack: DockerStack, service: String? = null): String? {
        if (service == null) return fill(template, stack, emptyMap())
        if (this != REBUILD || !isServiceName(service) || stack.containers.none { it.service == service }) return null
        return fill(SpecCommands.script("compose_rebuild_service"), stack, mapOf("service" to service))
    }

    fun intent(stack: DockerStack, service: String? = null): Intent? {
        val command = command(stack, service) ?: return null
        val summary = if (service != null) "$verb service $service of ${stack.name}" else "$verb stack ${stack.name}"
        return Intent(summary, command, Risk.MUTATE)
    }

    companion object {
        /**
         * Compose service names: letters, digits, `.`, `_`, `-`, starting with a letter or digit. The name comes from a
         * container label, so it is checked before it reaches a shell.
         */
        internal fun isServiceName(name: String): Boolean {
            if (name.isEmpty() || name.length > 64) return false
            val first = name.first()
            if (!(first.isAsciiLetter() || first in '0'..'9')) return false
            return name.all { it.isAsciiLetter() || it in '0'..'9' || it == '-' || it == '_' || it == '.' }
        }

        private fun Char.isAsciiLetter() = this in 'a'..'z' || this in 'A'..'Z'

        internal fun fill(template: String, stack: DockerStack, extra: Map<String, String>): String? {
            val paths = stack.configFiles.ifEmpty { listOfNotNull(stack.configFile) }
            // A comma inside a real path would have been split by the label parser, leaving a non-absolute piece, which
            // quotePath refuses, so a mangled list never reaches the shell.
            val files = paths.mapNotNull { ShellQuote.quotePath(it) }
            val dir = stack.workingDir?.let { ShellQuote.quotePath(it) }
            if (stack.isStandalone || !DockerSession.isComposeProjectName(stack.name) || dir == null || paths.isEmpty() || files.size != paths.size) return null
            return Template.fill(
                template,
                mapOf("dir" to dir, "project" to stack.name, "files" to files.joinToString(" ") { "-f $it" }) + extra,
            )
        }
    }
}

data class DockerState(
    val snapshot: DockerSnapshot? = null,
    /** Why the last poll failed. The last good snapshot stays visible beside it. */
    val error: String? = null,
    val updatedAt: Long? = null,
    /** Containers with an action in flight. */
    val busy: Set<String> = emptySet(),
    /**
     * Stacks with a whole-stack action in flight, by [DockerStack.id] (a compose project's name, or `standalone/<container>`).
     * Not by container id: `up -d` creates containers with new ids, and the poll keeps replacing the snapshot underneath a
     * long action.
     */
    val busyStacks: Set<String> = emptySet(),
    /** Why the last action failed, until the next action starts. */
    val actionError: String? = null,
)

/**
 * Polls `docker ps` and `docker stats` for one server and runs start, stop and restart. Separate from [ServerSession] because
 * `docker stats` takes about 2 s, so it polls more slowly and only while the Docker screen is open.
 */
class DockerSession(
    private val transport: SSHTransport,
    private val intervalMillis: Long = 10_000,
    private val policy: ActionPolicy = ActionPolicy(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    companion object {
        val command: String get() = SpecCommands.script("docker")

        /** Container ids come from docker, but we still refuse anything that is not a hex id before it reaches a shell. */
        fun actionCommand(action: DockerAction, id: String): String? =
            if (isContainerID(id)) Template.fill(SpecCommands.script("docker_${action.raw}"), mapOf("id" to id)) else null

        /** An interactive shell inside a container, for a terminal (a pty command). Prefers bash, falls back to sh. */
        fun shellCommand(id: String): String? =
            if (isContainerID(id)) Template.fill(SpecCommands.script("docker_shell"), mapOf("id" to id)) else null

        /** Follow a container's logs (last 100 lines first). Same id validation as actions. */
        fun logsCommand(id: String): String? =
            if (isContainerID(id)) Template.fill(SpecCommands.script("docker_logs"), mapOf("id" to id)) else null

        /** Compose project names are lowercase letters, digits, `-` and `_`, starting with a letter or digit. */
        internal fun isComposeProjectName(name: String): Boolean {
            if (name.isEmpty()) return false
            val first = name.first()
            if (!(first in 'a'..'z' || first in '0'..'9')) return false
            return name.all { it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' }
        }

        internal fun isContainerID(id: String): Boolean = id.length in 12..64 && id.all { it in '0'..'9' || it in 'a'..'f' }
    }

    private val _state = MutableStateFlow(DockerState())
    val state: StateFlow<DockerState> = _state.asStateFlow()
    private var loop: Job? = null

    fun start(scope: CoroutineScope) {
        if (loop != null) return
        loop = scope.launch {
            while (isActive) {
                refresh()
                delay(intervalMillis)
            }
        }
    }

    fun stop() {
        loop?.cancel()
        loop = null
    }

    suspend fun refresh() {
        try {
            val result = transport.run(command, 20_000)
            if (result.exitCode != 0) throw SessionError.CommandFailed(result.exitCode, result.stderr.trim())
            val snapshot = DockerParser.parse(result.stdout)
            _state.update { it.copy(snapshot = snapshot, error = null, updatedAt = clock()) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(error = e.message ?: e.toString()) }
        }
    }

    /** Call after the user has agreed (or straight away for actions the UI treats as low-risk). */
    fun confirm(action: DockerAction, containerID: String): Confirmation {
        val intent = action.intent(containerID) ?: throw PolicyError.InvalidTarget
        return policy.confirm(intent)
    }

    fun confirm(action: ComposeAction, stack: DockerStack, service: String? = null): Confirmation {
        val intent = action.intent(stack, service) ?: throw PolicyError.InvalidTarget
        return policy.confirm(intent)
    }

    private fun fail(message: String?) = _state.update { it.copy(actionError = message) }

    /** Runs a whole-stack compose action, then refreshes. All the stack's containers show as busy meanwhile. */
    suspend fun perform(action: ComposeAction, stack: DockerStack, confirmation: Confirmation?) {
        val intent = action.intent(stack) ?: return fail("Refusing to ${action.raw} ${stack.name}: it has no usable compose project.")
        try { policy.authorize(intent, confirmation) } catch (e: PolicyError) { return fail(e.message) }
        val ids = stack.containers.map { it.id }.toSet()
        _state.update { it.copy(busy = it.busy + ids, busyStacks = it.busyStacks + stack.id, actionError = null) }

        var failure: String? = null
        try {
            val result = transport.run(intent.command, action.timeoutMillis)
            if (result.exitCode != 0) {
                val detail = result.stderr.trim()
                // Compose writes progress to stderr too; the last lines carry the reason.
                val tail = detail.split('\n').filter { it.isNotEmpty() }.takeLast(3).joinToString("\n")
                failure = tail.ifEmpty { "docker compose ${action.raw} failed (exit ${result.exitCode})" }
            }
        } catch (e: CancellationException) {
            _state.update { it.copy(busy = it.busy - ids, busyStacks = it.busyStacks - stack.id) }
            throw e
        } catch (e: Exception) {
            failure = e.message ?: e.toString()
        }
        _state.update { it.copy(busy = it.busy - ids, busyStacks = it.busyStacks - stack.id, actionError = failure) }
        refresh()
    }

    /**
     * Runs a whole-stack compose action with live output and then refreshes. The command is the same one `perform` runs; only
     * the way it is run differs (a pty, so compose draws its normal progress, and an exit-code marker). Cancelling the calling
     * coroutine stops the remote command (Ctrl-C through the pty).
     */
    suspend fun performStreaming(
        action: ComposeAction, stack: DockerStack, service: String? = null, confirmation: Confirmation?,
        cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit,
    ) {
        val intent = action.intent(stack, service)
        if (intent == null) {
            fail("Refusing to ${action.raw} ${stack.name}: it has no usable compose project.")
            onEvent(ActionStreamEvent.Finished(null))
            return
        }
        val scoped = if (service == null) stack.containers else stack.containers.filter { it.service == service }
        stream(intent, confirmation, scoped.map { it.id }.toSet(), stack.id, "docker compose ${action.raw}", cols, rows, onEvent)
    }

    fun confirm(removal: StackRemoval, stack: DockerStack): Confirmation {
        val intent = removal.intent(stack) ?: throw PolicyError.InvalidTarget
        return policy.confirm(intent)
    }

    /** Deletes the stack (see [StackRemoval]) with live output, then refreshes. Same pty streaming as the other stack actions. */
    suspend fun performStreaming(
        removal: StackRemoval, stack: DockerStack, confirmation: Confirmation?,
        cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit,
    ) {
        val intent = removal.intent(stack)
        if (intent == null) {
            fail("Refusing to delete ${stack.name}: it has no usable compose project, or its folder can't be deleted safely.")
            onEvent(ActionStreamEvent.Finished(null))
            return
        }
        stream(intent, confirmation, stack.containers.map { it.id }.toSet(), stack.id, "docker compose down", cols, rows, onEvent)
    }

    fun confirm(action: StandaloneAction, stack: DockerStack): Confirmation {
        val intent = action.intent(stack) ?: throw PolicyError.InvalidTarget
        return policy.confirm(intent)
    }

    /**
     * Pulls a standalone container's image or deletes the container, with live output, then refreshes. The stack is busy under
     * its id (`standalone/<name>`), which can't clash with a compose project's name.
     */
    suspend fun performStreaming(
        action: StandaloneAction, stack: DockerStack, confirmation: Confirmation?,
        cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit,
    ) {
        val intent = action.intent(stack)
        if (intent == null) {
            fail("Refusing to change ${stack.name}: it is not a single standalone container with a usable id and image.")
            onEvent(ActionStreamEvent.Finished(null))
            return
        }
        val label = when (action) {
            StandaloneAction.PullImage -> "docker pull"
            is StandaloneAction.Remove -> "docker rm"
        }
        stream(intent, confirmation, stack.containers.map { it.id }.toSet(), stack.id, label, cols, rows, onEvent)
    }

    /** The same for one container's start, stop or restart, so every action shows up in the same live output. */
    suspend fun performStreaming(
        action: DockerAction, containerID: String, confirmation: Confirmation?,
        cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit,
    ) {
        val intent = action.intent(containerID)
        if (intent == null) {
            fail("Refusing to run ${action.raw}: invalid container id.")
            onEvent(ActionStreamEvent.Finished(null))
            return
        }
        stream(intent, confirmation, setOf(containerID), null, "docker ${action.raw}", cols, rows, onEvent)
    }

    private suspend fun stream(
        intent: Intent, confirmation: Confirmation?, ids: Set<String>, stackId: String?, label: String,
        cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit,
    ) {
        try {
            policy.authorize(intent, confirmation)
        } catch (e: PolicyError) {
            fail(e.message)
            onEvent(ActionStreamEvent.Finished(null))
            return
        }
        _state.update { it.copy(busy = it.busy + ids, busyStacks = if (stackId != null) it.busyStacks + stackId else it.busyStacks, actionError = null) }
        val run = StreamRunner.run(transport, intent.command, cols, rows, onEvent)
        val failure = run.failureMessage(label)
        _state.update {
            it.copy(busy = it.busy - ids, busyStacks = if (stackId != null) it.busyStacks - stackId else it.busyStacks, actionError = failure)
        }
        refresh()
    }

    /** Runs the action, then refreshes so the list shows the result. */
    suspend fun perform(action: DockerAction, containerID: String, confirmation: Confirmation?) {
        val intent = action.intent(containerID) ?: return fail("Refusing to run ${action.raw}: invalid container id.")
        try { policy.authorize(intent, confirmation) } catch (e: PolicyError) { return fail(e.message) }
        _state.update { it.copy(busy = it.busy + containerID, actionError = null) }

        var failure: String? = null
        try {
            val result = transport.run(intent.command, 60_000)
            if (result.exitCode != 0) {
                val detail = result.stderr.trim()
                failure = detail.ifEmpty { "docker ${action.raw} failed (exit ${result.exitCode})" }
            }
        } catch (e: CancellationException) {
            _state.update { it.copy(busy = it.busy - containerID) }
            throw e
        } catch (e: Exception) {
            failure = e.message ?: e.toString()
        }
        _state.update { it.copy(busy = it.busy - containerID, actionError = failure) }
        refresh()
    }
}
