package com.bgallagher.rackoon.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class UpdatesState(
    val snapshot: UpdatesSnapshot? = null,
    /** Why the last refresh failed. The last good snapshot stays beside it. */
    val error: String? = null,
    val updatedAt: Long? = null,
    /** An apt action is running. */
    val isWorking: Boolean = false,
    /** Why the last apt action failed, until the next one starts. */
    val actionError: String? = null,
    /** Tail of the last successful action's output, for a "done" message. */
    val actionOutput: String? = null,
)

/**
 * Reads one server's pending apt updates. Read-only: it reports what apt already knows from its cache and never refreshes
 * it or installs anything (that needs root and goes through [ActionPolicy]).
 */
class UpdatesSession(
    private val transport: SSHTransport,
    private val policy: ActionPolicy = ActionPolicy(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    companion object {
        val command: String get() = SpecCommands.script("updates")
    }

    private val _state = MutableStateFlow(UpdatesState())
    val state: StateFlow<UpdatesState> = _state.asStateFlow()

    fun confirm(action: AptAction): Confirmation {
        val intent = action.intent ?: throw PolicyError.InvalidTarget
        return policy.confirm(intent)
    }

    /**
     * Runs an apt action with its output streamed live (over a pty, so apt draws its normal progress), then re-reads the
     * update list. Ignored while another action is running. Cancelling the calling coroutine stops apt on the server.
     */
    suspend fun performStreaming(action: AptAction, confirmation: Confirmation?, cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit) {
        if (_state.value.isWorking) { onEvent(ActionStreamEvent.Finished(null)); return }
        _state.update { it.copy(actionError = null, actionOutput = null) }
        val intent = action.intent
        if (intent == null) {
            _state.update { it.copy(actionError = "Refusing to run apt: invalid package name.") }
            onEvent(ActionStreamEvent.Finished(null))
            return
        }
        try {
            policy.authorize(intent, confirmation)
        } catch (e: PolicyError) {
            _state.update { it.copy(actionError = e.message) }
            onEvent(ActionStreamEvent.Finished(null))
            return
        }
        _state.update { it.copy(isWorking = true) }
        val run = StreamRunner.run(transport, intent.command, cols, rows, onEvent)
        val plain = ANSI.strip(run.text)
        _state.update {
            when {
                run.succeeded -> it.copy(actionOutput = plain.split('\n').filter { l -> l.isNotEmpty() }.takeLast(5).joinToString("\n"))
                // Known causes get a readable sentence (sudo asking for a password, another apt holding the lock).
                run.exitCode != null -> it.copy(actionError = AptAction.explain(stdout = plain, stderr = "", exitCode = run.exitCode))
                else -> it.copy(actionError = run.failureMessage("apt"))
            }
        }
        _state.update { it.copy(isWorking = false) }
        refresh()
    }

    /** Runs an apt action, then re-reads the update list. Ignored while another action is running. */
    suspend fun perform(action: AptAction, confirmation: Confirmation?) {
        if (_state.value.isWorking) return
        _state.update { it.copy(actionError = null, actionOutput = null) }
        val intent = action.intent
        if (intent == null) {
            _state.update { it.copy(actionError = "Refusing to run apt: invalid package name.") }
            return
        }
        try {
            policy.authorize(intent, confirmation)
        } catch (e: PolicyError) {
            _state.update { it.copy(actionError = e.message) }
            return
        }
        _state.update { it.copy(isWorking = true) }
        try {
            val result = transport.run(intent.command, action.timeoutMillis)
            _state.update {
                if (result.exitCode == 0) it.copy(actionOutput = result.stdout.split('\n').filter { l -> l.isNotEmpty() }.takeLast(5).joinToString("\n"))
                else it.copy(actionError = AptAction.explain(result.stdout, result.stderr, result.exitCode))
            }
        } catch (e: CancellationException) {
            _state.update { it.copy(isWorking = false) }
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(actionError = e.message ?: e.toString()) }
        }
        _state.update { it.copy(isWorking = false) }
        refresh()
    }

    suspend fun refresh(): UpdatesState {
        try {
            val result = transport.run(command, 20_000)
            // The command ends with a conditional that always succeeds, so a non-zero exit means ssh itself failed.
            if (result.exitCode != 0) {
                val detail = result.stderr.trim()
                throw IllegalStateException(detail.ifEmpty { "ssh exited ${result.exitCode}" })
            }
            val snapshot = UpdatesParser.parse(result.stdout)
            _state.update { it.copy(snapshot = snapshot, error = null, updatedAt = clock()) }
        } catch (e: UpdatesParseError.NotInstalled) {
            _state.update { it.copy(error = "apt is not installed on this server.") }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(error = e.message ?: e.toString()) }
        }
        return _state.value
    }
}
