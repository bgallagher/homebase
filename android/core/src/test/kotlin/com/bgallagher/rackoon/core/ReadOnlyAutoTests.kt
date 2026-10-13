package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReadOnlyAutoTests {
    private val minute = 60_000L

    @Test fun idleModesSwitchBackAfterTheirTime() {
        assertFalse(AutoReadOnly.shouldReenable(AutoReadOnly.IDLE_5, readOnly = false, lastTouchMillis = 0, nowMillis = 4 * minute, busy = false))
        assertTrue(AutoReadOnly.shouldReenable(AutoReadOnly.IDLE_5, readOnly = false, lastTouchMillis = 0, nowMillis = 5 * minute, busy = false))
        assertFalse(AutoReadOnly.shouldReenable(AutoReadOnly.IDLE_15, readOnly = false, lastTouchMillis = 0, nowMillis = 14 * minute, busy = false))
        assertTrue(AutoReadOnly.shouldReenable(AutoReadOnly.IDLE_15, readOnly = false, lastTouchMillis = 0, nowMillis = 15 * minute, busy = false))
    }

    @Test fun neverAndBackgroundModesIgnoreIdleTime() {
        assertFalse(AutoReadOnly.shouldReenable(AutoReadOnly.NEVER, false, 0, 999 * minute, false))
        assertFalse(AutoReadOnly.shouldReenable(AutoReadOnly.BACKGROUND, false, 0, 999 * minute, false))
    }

    @Test fun aRunningActionOrAlreadyReadOnlyIsLeftAlone() {
        assertFalse(AutoReadOnly.shouldReenable(AutoReadOnly.IDLE_5, readOnly = false, lastTouchMillis = 0, nowMillis = 60 * minute, busy = true))
        assertFalse(AutoReadOnly.shouldReenable(AutoReadOnly.IDLE_5, readOnly = true, lastTouchMillis = 0, nowMillis = 60 * minute, busy = false))
    }

    @Test fun backgroundModeSwitchesOnLeavingTheApp() {
        assertTrue(AutoReadOnly.shouldReenableOnBackground(AutoReadOnly.BACKGROUND, readOnly = false, busy = false))
        assertFalse(AutoReadOnly.shouldReenableOnBackground(AutoReadOnly.BACKGROUND, readOnly = false, busy = true))
        assertFalse(AutoReadOnly.shouldReenableOnBackground(AutoReadOnly.IDLE_15, readOnly = false, busy = false))
        assertFalse(AutoReadOnly.shouldReenableOnBackground(AutoReadOnly.BACKGROUND, readOnly = true, busy = false))
    }

    @Test fun keysRoundTripAndUnknownFallsBackToTheDefault() {
        AutoReadOnly.entries.forEach { assertEquals(it, AutoReadOnly.fromKey(it.key)) }
        assertEquals(AutoReadOnly.IDLE_15, AutoReadOnly.fromKey("nonsense"))
        assertEquals(AutoReadOnly.IDLE_15, AutoReadOnly.fromKey(null))
    }
}
