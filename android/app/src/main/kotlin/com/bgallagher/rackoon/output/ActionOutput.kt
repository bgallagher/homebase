package com.bgallagher.rackoon.output

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.bgallagher.rackoon.core.ActionStreamEvent
import com.bgallagher.rackoon.core.TerminalTheme
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.connectbot.terminal.TerminalEmulator
import org.connectbot.terminal.TerminalEmulatorFactory

/**
 * One streamed action (a stack or container action): its output in a read-only terminal emulator, its state, and the size of the
 * view that shows it. The run starts only once that view has reported its size, so the remote pty (and compose's cursor-moving
 * progress) matches it. Lives in the view-model, so leaving the screen or turning the phone does not lose it.
 */
class ActionOutput(
    /** What the run belongs to: a stack's [com.bgallagher.rackoon.core.DockerStack.id] (a compose project name or `standalone/<container>`). The stack page shows only its own. */
    val scope: String,
    val title: String,
    private val coroutines: CoroutineScope,
) {
    sealed class Phase {
        object Starting : Phase()
        object Running : Phase()
        object Succeeded : Phase()
        data class Failed(val exitCode: Int?) : Phase()
        object Cancelled : Phase()
    }

    private val sized = CompletableDeferred<Unit>()
    private val _phase = MutableStateFlow<Phase>(Phase.Starting)
    val phase: StateFlow<Phase> = _phase.asStateFlow()
    private var job: Job? = null
    private var exitCode: Int? = null
    private var sawFinish = false

    val emulator: TerminalEmulator = TerminalEmulatorFactory.create(
        defaultForeground = Color.White, defaultBackground = Color.Black,
        onKeyboardInput = {},   // read-only: there is nothing to send
        onResize = { sized.complete(Unit) },
    )

    val isRunning: Boolean get() = phase.value == Phase.Starting || phase.value == Phase.Running

    fun applyTheme(theme: TerminalTheme) {
        val ansi = theme.ansiRGB.map { Color(it.r, it.g, it.b).toArgb() }.toIntArray()
        emulator.applyColorScheme(ansi, Color(theme.foregroundRGB.r, theme.foregroundRGB.g, theme.foregroundRGB.b).toArgb(), Color(theme.backgroundRGB.r, theme.backgroundRGB.g, theme.backgroundRGB.b).toArgb())
    }

    private fun show(text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.isNotEmpty()) emulator.writeInput(bytes, 0, bytes.size)
    }

    /**
     * Starts the run. [work] is handed the terminal's real size and a sink for events, and returns when the command has finished.
     * [completion] runs once the output is complete (the view-model clears its "working" label there).
     */
    fun start(intro: String? = null, work: suspend (cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit) -> Unit, completion: () -> Unit) {
        job = coroutines.launch {
            val gotSize = withTimeoutOrNull(2_000) { sized.await() } != null
            // The first report can be a default size, before layout settles.
            if (gotSize) delay(250)
            val dim = emulator.dimensions
            intro?.let { show(it) }
            _phase.value = Phase.Running
            try {
                work(dim.columns.coerceAtLeast(20), dim.rows.coerceAtLeast(4)) { event ->
                    when (event) {
                        is ActionStreamEvent.Output -> show(event.text)
                        is ActionStreamEvent.Finished -> { sawFinish = true; exitCode = event.exitCode }
                    }
                }
            } finally {
                // Asked here, before the cleanup block: inside it the coroutine is deliberately not cancellable.
                val cancelled = !isActive
                withContext(NonCancellable) {
                    _phase.value = when {
                        cancelled -> Phase.Cancelled
                        sawFinish && exitCode == 0 -> Phase.Succeeded
                        else -> Phase.Failed(exitCode)
                    }
                    completion()
                }
            }
        }
    }

    /** Stops the running action (Ctrl-C reaches the command on the server). */
    fun cancel() { job?.cancel() }
}
