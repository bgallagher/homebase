package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals

class ReconnectPolicyTests {
    private fun retry(p: ReconnectPolicy, connected: Long = 0) = p.onEnded(SessionEnd.ConnectionLost, connected)

    @Test fun backsOffThroughFiveAttemptsThenGivesUp() {
        val p = ReconnectPolicy()
        assertEquals(listOf(1000L, 2000L, 4000L, 8000L, 15000L), (1..5).map { (retry(p) as ReconnectDecision.Retry).delayMillis })
        assertEquals(ReconnectDecision.GiveUp, retry(p))
    }

    @Test fun reportsTheAttemptNumber() {
        val p = ReconnectPolicy()
        assertEquals(ReconnectDecision.Retry(1000, 1, 5), retry(p))
        assertEquals(ReconnectDecision.Retry(2000, 2, 5), retry(p))
    }

    @Test fun onlyALostConnectionIsRetried() {
        val p = ReconnectPolicy()
        assertEquals(ReconnectDecision.GiveUp, p.onEnded(SessionEnd.RemoteExit(0), 60_000))
        assertEquals(ReconnectDecision.GiveUp, p.onEnded(SessionEnd.RemoteExit(1), 60_000))
        assertEquals(ReconnectDecision.GiveUp, p.onEnded(SessionEnd.ClosedByUser, 60_000))
        assertEquals(ReconnectDecision.Retry(1000, 1, 5), retry(p), "the budget was untouched")
    }

    @Test fun aSessionThatLastedTenSecondsEarnsAFreshBudget() {
        val p = ReconnectPolicy()
        repeat(4) { retry(p) }
        assertEquals(ReconnectDecision.Retry(1000, 1, 5), retry(p, connected = 10_000))
        assertEquals(ReconnectDecision.Retry(2000, 2, 5), retry(p, connected = 9_999), "just under ten seconds does not")
    }

    @Test fun resetForgetsEarlierFailures() {
        val p = ReconnectPolicy()
        repeat(3) { retry(p) }
        p.reset()
        assertEquals(ReconnectDecision.Retry(1000, 1, 5), retry(p))
    }
}
