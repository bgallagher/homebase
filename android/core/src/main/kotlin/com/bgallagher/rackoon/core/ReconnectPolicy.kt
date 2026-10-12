package com.bgallagher.rackoon.core

/** Why a terminal session ended. Only a lost connection is ever retried: the user closing it or the remote shell exiting is final. */
sealed class SessionEnd {
    /** The connection failed or dropped (ssh could not start, or the link went away). */
    object ConnectionLost : SessionEnd()

    /** The remote command or shell ended on its own, with this status. */
    data class RemoteExit(val code: Int) : SessionEnd()

    /** The user closed it. */
    object ClosedByUser : SessionEnd()
}

sealed class ReconnectDecision {
    /** Try again after `delayMillis`; this is attempt `attempt` of `of`. */
    data class Retry(val delayMillis: Long, val attempt: Int, val of: Int) : ReconnectDecision()

    object GiveUp : ReconnectDecision()
}

/**
 * The terminal's auto-reconnect rule, the same as the Mac app: retry only when the connection was lost, up to 5 times with
 * 1/2/4/8/15 s of backoff, and a session that lasted 10 s or more earns a fresh budget (so a long-lived session that drops
 * once is not penalised by earlier flapping). Pure and deterministic.
 */
class ReconnectPolicy(
    private val delaysSeconds: List<Int> = listOf(1, 2, 4, 8, 15),
    private val freshBudgetAfterMillis: Long = 10_000,
) {
    private var used = 0

    val maxAttempts: Int get() = delaysSeconds.size

    /** Called when a session (or a reconnect attempt) ends, with how long it had been connected. */
    fun onEnded(end: SessionEnd, connectedMillis: Long): ReconnectDecision {
        if (end !is SessionEnd.ConnectionLost) return ReconnectDecision.GiveUp
        if (connectedMillis >= freshBudgetAfterMillis) used = 0
        if (used >= maxAttempts) return ReconnectDecision.GiveUp
        val delay = delaysSeconds[used] * 1000L
        used++
        return ReconnectDecision.Retry(delay, used, maxAttempts)
    }

    /** The user pressed Reconnect now, or a new session started on purpose: forget earlier failures. */
    fun reset() { used = 0 }
}
