package com.bgallagher.rackoon.terminal

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.bgallagher.rackoon.core.RGB
import com.bgallagher.rackoon.core.ReconnectDecision
import com.bgallagher.rackoon.core.ReconnectPolicy
import com.bgallagher.rackoon.core.SessionEnd
import com.bgallagher.rackoon.core.TerminalOutputFilter
import com.bgallagher.rackoon.core.TerminalTheme
import com.bgallagher.rackoon.ssh.ShellSession
import com.bgallagher.rackoon.ssh.SshException
import com.bgallagher.rackoon.ssh.ServerConnection
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.connectbot.terminal.TerminalEmulator
import org.connectbot.terminal.TerminalEmulatorFactory

private fun RGB.toColor() = Color(r, g, b)

/** Where a terminal tab is in its life, in terms the screen can show. */
sealed class TabState {
    /** Waiting for the view to be measured, or connecting. */
    object Connecting : TabState()
    object Live : TabState()
    /** Connection lost: the next attempt starts in [seconds]. */
    data class Reconnecting(val attempt: Int, val of: Int, val seconds: Int) : TabState()
    data class Ended(val message: String, val remoteExit: Int? = null) : TabState()
}

/**
 * One terminal session: a termlib emulator fed by a shell on the server's SSH connection. The emulator outlives the shell, so
 * scrollback survives a reconnect (a dim notice is printed into it). The pty is allocated at the emulator's measured size and
 * resized with it. Reconnects follow [ReconnectPolicy] (the same rule as the Mac app) and happen only after a lost connection.
 */
class TerminalTab(
    val id: Int,
    val title: String,
    private val transport: ServerConnection,
    private val scope: CoroutineScope,
    theme: TerminalTheme,
    highlight: Boolean,
) {
    private val outbound = Channel<ByteArray>(Channel.UNLIMITED)
    private val sized = CompletableDeferred<Unit>()
    private val resizes = MutableStateFlow(0 to 0)
    private val kick = Channel<Unit>(Channel.CONFLATED)
    private val policy = ReconnectPolicy()
    private val filter = TerminalOutputFilter().also { it.isEnabled = highlight }
    @Volatile private var shell: ShellSession? = null
    private var loop: Job? = null

    private val _state = MutableStateFlow<TabState>(TabState.Connecting)
    val state: StateFlow<TabState> = _state.asStateFlow()

    /** Sticky modifiers from the extra-keys row; each applies to the next key and is then released. */
    private val _ctrl = MutableStateFlow(false)
    val ctrl: StateFlow<Boolean> = _ctrl.asStateFlow()
    private val _alt = MutableStateFlow(false)
    val alt: StateFlow<Boolean> = _alt.asStateFlow()

    val emulator: TerminalEmulator = TerminalEmulatorFactory.create(
        defaultForeground = theme.foregroundRGB.toColor(),
        defaultBackground = theme.backgroundRGB.toColor(),
        onKeyboardInput = { send(it) },
        onResize = { d ->
            resizes.value = d.columns to d.rows
            sized.complete(Unit)
        },
    )

    init {
        applyTheme(theme)
        scope.launch { for (bytes in outbound) shell?.write(bytes) }
        scope.launch {
            resizes.collectLatest { (c, r) ->
                if (c > 0 && r > 0) { delay(150); shell?.resize(c, r) }   // layout settles in several steps: debounce
            }
        }
        start()
    }

    fun applyTheme(theme: TerminalTheme) {
        val ansi = theme.ansiRGB.map { it.toColor().toArgb() }.toIntArray()
        emulator.applyColorScheme(ansi, theme.foregroundRGB.toColor().toArgb(), theme.backgroundRGB.toColor().toArgb())
    }

    fun setHighlight(on: Boolean) { filter.isEnabled = on }

    fun toggleCtrl() { _ctrl.value = !_ctrl.value }
    fun toggleAlt() { _alt.value = !_alt.value }

    /** Input from the soft keyboard or the extra keys. Armed Ctrl turns a letter into its control code; Alt prefixes Escape. */
    fun send(bytes: ByteArray) {
        var out = bytes
        if (_ctrl.value && out.size == 1) {
            val b = out[0].toInt()
            val code = when (b) {
                in 'a'.code..'z'.code -> b - 'a'.code + 1
                in 'A'.code..'Z'.code -> b - 'A'.code + 1
                '['.code -> 27; '\\'.code -> 28; ']'.code -> 29; ' '.code -> 0
                else -> -1
            }
            if (code >= 0) { out = byteArrayOf(code.toByte()); _ctrl.value = false }
        }
        if (_alt.value && out.isNotEmpty()) { out = byteArrayOf(27) + out; _alt.value = false }
        outbound.trySend(out)
    }

    fun sendText(text: String) = send(text.toByteArray())

    /** Starts (or restarts, after it ended) the connect-and-reconnect loop. */
    fun start() {
        if (loop?.isActive == true) return
        policy.reset()
        loop = scope.launch { run() }
    }

    /** "Reconnect now": skips a countdown, or starts again after the session gave up. */
    fun reconnectNow() {
        if (loop?.isActive == true) kick.trySend(Unit) else start()
    }

    fun close() {
        loop?.cancel()
        outbound.close()
        scope.launch { shell?.close(); shell = null }
    }

    private suspend fun run() {
        sized.await()
        while (true) {
            _state.value = TabState.Connecting
            var connectedAt = 0L
            val end: SessionEnd = try {
                val dim = emulator.dimensions
                val s = transport.openShell(dim.columns, dim.rows)
                shell = s
                connectedAt = System.currentTimeMillis()
                _state.value = TabState.Live
                // The size may have changed while connecting.
                resizes.value.let { (c, r) -> if (c > 0 && r > 0 && (c != dim.columns || r != dim.rows)) s.resize(c, r) }
                val pump = scope.launch {
                    s.output.collect { chunk ->
                        val shown = filter.process(chunk)
                        if (shown.isNotEmpty()) emulator.writeInput(shown, 0, shown.size)
                    }
                }
                val e = s.awaitEnd()
                pump.join()
                e
            } catch (e: SshException.HostKeyChanged) {
                _state.value = TabState.Ended("The server's host key changed. The connection was blocked.")
                return
            } catch (e: SshException.HostKeyUnknown) {
                _state.value = TabState.Ended("This server's host key isn't trusted yet. Open Overview and trust it first.")
                return
            } catch (e: SshException.AuthFailed) {
                _state.value = TabState.Ended("Sign-in was refused: ${e.detail}")
                return
            } catch (e: SshException) {
                SessionEnd.ConnectionLost
            }
            shell = null
            val connectedFor = if (connectedAt > 0) System.currentTimeMillis() - connectedAt else 0
            if (end is SessionEnd.ClosedByUser) return
            when (val d = policy.onEnded(end, connectedFor)) {
                is ReconnectDecision.GiveUp -> {
                    _state.value = when (end) {
                        is SessionEnd.RemoteExit -> TabState.Ended(if (end.code == 0) "Session ended." else "Session ended (exit ${end.code}).", end.code)
                        else -> TabState.Ended("Connection lost. Couldn't reconnect.")
                    }
                    return
                }
                is ReconnectDecision.Retry -> {
                    notice("connection lost, reconnecting…")
                    var left = (d.delayMillis / 1000).toInt()
                    while (left > 0) {
                        _state.value = TabState.Reconnecting(d.attempt, d.of, left)
                        if (withTimeoutOrNull(1_000) { kick.receive() } != null) break
                        left--
                    }
                }
            }
        }
    }

    /** A dim line in the scrollback (the previous output stays visible above it). */
    private fun notice(text: String) {
        val bytes = "\r\n\u001B[2m[$text]\u001B[0m\r\n".toByteArray()
        emulator.writeInput(bytes, 0, bytes.size)
    }
}
