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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ServerState(
    val overview: Overview? = null,
    val cpuPercent: Double? = null,
    val attention: List<AttentionItem> = emptyList(),
    val error: String? = null,
    /** Epoch milliseconds of the last successful poll (or of the cached snapshot). */
    val updatedAt: Long? = null,
    /** True while `overview` is a cached snapshot from an earlier run, not yet refreshed. */
    val isStale: Boolean = false,
)

sealed class SessionError(message: String) : Exception(message) {
    class CommandFailed(val code: Int, val detail: String) : SessionError(detail.ifEmpty { "Command failed (exit $code)" })
}

/** Owns one server's transport and poll loop. Views never call SSH directly. */
class ServerSession(
    private val transport: SSHTransport,
    private val intervalMillis: Long = 5_000,
    cached: Cached? = null,
    private val onSnapshot: ((Overview) -> Unit)? = null,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** A snapshot saved by an earlier run, shown immediately (marked stale) until the first successful poll. */
    class Cached(val overview: Overview, val savedAt: Long)

    companion object {
        val overviewCommand: String get() = SpecCommands.script("overview")
    }

    private val _state = MutableStateFlow(
        if (cached != null) ServerState(cached.overview, null, Attention.evaluate(cached.overview), null, cached.savedAt, true) else ServerState(),
    )

    /** The current state, and every refresh after it. */
    val state: StateFlow<ServerState> = _state.asStateFlow()

    private var previous: Overview? = null
    private var loop: Job? = null
    private val refreshLock = Mutex()

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

    /** One poll. Public so callers (and tests) can refresh on demand. */
    suspend fun refresh() = refreshLock.withLock {
        try {
            val result = transport.run(overviewCommand, 10_000)
            if (result.exitCode != 0) throw SessionError.CommandFailed(result.exitCode, result.stderr.trim())
            val overview = OverviewParser.parse(result.stdout)
            val cpu = previous?.let { overview.cpuPercent(it) }
            _state.update {
                it.copy(
                    cpuPercent = cpu ?: it.cpuPercent, overview = overview, attention = Attention.evaluate(overview),
                    error = null, updatedAt = clock(), isStale = false,
                )
            }
            previous = overview
            onSnapshot?.invoke(overview)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Keep the last good data on screen and surface the error beside it.
            _state.update { it.copy(error = e.message ?: e.toString()) }
        }
    }
}
