package com.bgallagher.rackoon.core

/** When Read-only turns itself back on after the user switched it off. */
enum class AutoReadOnly(val key: String, val label: String, val idleMinutes: Int?, val onBackground: Boolean) {
    NEVER("never", "Never", null, false),
    IDLE_5("idle5", "After 5 minutes idle", 5, false),
    IDLE_15("idle15", "After 15 minutes idle", 15, false),
    BACKGROUND("background", "When the app is backgrounded", null, true);

    companion object {
        val DEFAULT = IDLE_15
        fun fromKey(key: String?): AutoReadOnly = entries.firstOrNull { it.key == key } ?: DEFAULT

        /**
         * True when Read-only should switch itself back on now: changes are allowed, the mode is an idle one, nothing has touched
         * the app for long enough, and no action is running (a stream in flight is never interrupted by this).
         */
        fun shouldReenable(mode: AutoReadOnly, readOnly: Boolean, lastTouchMillis: Long, nowMillis: Long, busy: Boolean): Boolean {
            val minutes = mode.idleMinutes ?: return false
            if (readOnly || busy) return false
            return nowMillis - lastTouchMillis >= minutes * 60_000L
        }

        /** True when leaving the app should switch Read-only back on (and nothing is running). */
        fun shouldReenableOnBackground(mode: AutoReadOnly, readOnly: Boolean, busy: Boolean): Boolean = mode.onBackground && !readOnly && !busy
    }
}
