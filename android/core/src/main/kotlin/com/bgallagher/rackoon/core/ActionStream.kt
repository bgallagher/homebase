package com.bgallagher.rackoon.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

/**
 * Runs a command with live output over a pty and reports its exit code in-band, as a final marker line. (A streamed ssh
 * gives output but no exit status, so the wrapper prints `##rackoon-exit:<n>` itself.)
 */
object StreamedCommand {
    const val MARKER = "##rackoon-exit:"

    /**
     * `cols` and `rows` are the size of the terminal that will show the output, so progress that redraws itself (compose
     * moves the cursor up to update lines) lines up. The command itself must already be vetted.
     */
    fun wrap(command: String, cols: Int, rows: Int): String = Template.fill(
        SpecCommands.script("stream_wrap"),
        mapOf("cols" to cols.coerceIn(20, 400).toString(), "rows" to rows.coerceIn(5, 200).toString(), "command" to command),
    )
}

/**
 * Splits a stream into the text to show and the exit code marker at its end. Chunks can cut the marker anywhere, so a
 * possible start of it is held back until the next chunk shows what it is.
 */
class StreamOutputParser {
    private var pending = ""
    var exitCode: Int? = null
        private set

    /** Text that is safe to show now. */
    fun push(chunk: String): String {
        if (exitCode != null) return "" // nothing follows the marker
        pending += chunk
        val found = pending.indexOf(StreamedCommand.MARKER)
        if (found >= 0) {
            val shown = pending.substring(0, found)
            val rest = pending.substring(found + StreamedCommand.MARKER.length)
            val end = rest.indexOfFirst { it == '\n' || it == '\r' }
            if (end >= 0) {
                exitCode = leadingInt(rest.substring(0, end))
                pending = ""
            } else {
                pending = pending.substring(found) // the number has not fully arrived
            }
            return shown
        }
        // Hold back a tail that could be the start of the marker.
        var hold = 0
        for (length in minOf(StreamedCommand.MARKER.length - 1, pending.length) downTo 1) {
            if (StreamedCommand.MARKER.startsWith(pending.takeLast(length))) { hold = length; break }
        }
        val cut = pending.length - hold
        val shown = pending.substring(0, cut)
        pending = pending.substring(cut)
        return shown
    }

    /**
     * At the end of the stream: whatever was held back, and the exit code if the marker arrived (null if the connection
     * ended or the command was cancelled before it finished).
     */
    fun finish(): Pair<String, Int?> {
        val held = pending
        pending = ""
        if (exitCode == null) {
            val found = held.indexOf(StreamedCommand.MARKER)
            if (found >= 0) {
                // The marker was the last thing sent, without a trailing newline.
                val code = leadingInt(held.substring(found + StreamedCommand.MARKER.length))
                if (code != null) {
                    exitCode = code
                    return held.substring(0, found) to code
                }
            }
        }
        return (if (exitCode == null) held else "") to exitCode
    }

    /** The number at the start of `text`, ignoring spaces before it and anything after it. */
    private fun leadingInt(text: String): Int? = text.dropWhile { it == ' ' }.takeWhile { it in '0'..'9' }.toIntOrNull()
}

/** Reassembles UTF-8 from byte chunks that may cut a multi-byte character in two (compose prints a check mark). */
class Utf8Chunker {
    private var held = ByteArray(0)

    fun push(data: ByteArray): String {
        held += data
        // A character is at most 4 bytes (a lead byte and up to 3 continuations): hold back an incomplete tail.
        var end = held.size
        var back = 0
        while (back < 4 && end - back > 0) {
            val byte = held[end - back - 1].toInt() and 0xFF
            if (byte and 0b1100_0000 == 0b1000_0000) { back++; continue } // continuation byte: keep looking
            val needed = if (byte >= 0b1111_0000) 4 else if (byte >= 0b1110_0000) 3 else if (byte >= 0b1100_0000) 2 else 1
            if (needed > back + 1) end -= back + 1 // lead byte without its continuations
            break
        }
        val text = String(held, 0, end, Charsets.UTF_8)
        held = held.copyOfRange(end, held.size)
        return text
    }

    fun finish(): String {
        val text = if (held.isEmpty()) "" else String(held, Charsets.UTF_8)
        held = ByteArray(0)
        return text
    }
}

sealed class ActionStreamEvent {
    data class Output(val text: String) : ActionStreamEvent()

    /** `exitCode` is null if the connection ended or the run was cancelled before the command reported one. */
    data class Finished(val exitCode: Int?) : ActionStreamEvent()
}

object ANSI {
    private val csi = Regex("\u001B\\[[0-9;?]*[ -/]*[@-~]")
    private val charset = Regex("\u001B[()][0-9A-Za-z]")

    /** Text without terminal escape sequences and carriage returns, for matching on what a command printed. */
    fun strip(text: String): String = text.replace(csi, "").replace(charset, "").replace("\r", "")
}

/** What a streamed run came to. */
class StreamedRun(
    /** The command's own exit code; null if the connection ended or the run was cancelled before it reported one. */
    val exitCode: Int?,
    val cancelled: Boolean,
    /** Why the stream itself failed (ssh could not start, ...), if it did. */
    val transportError: String?,
    /** The visible text it printed, capped, for recognising known failures (sudo, apt lock) afterwards. */
    val text: String,
) {
    val succeeded: Boolean get() = exitCode == 0

    /** A short reason for a run that did not succeed, or null if it did. */
    fun failureMessage(label: String): String? {
        if (exitCode != null) return if (exitCode == 0) null else "$label failed (exit $exitCode). The output shows why."
        if (transportError != null) return transportError
        return if (cancelled) "Cancelled. The command was interrupted on the server." else "The connection ended before $label reported a result."
    }
}

object StreamRunner {
    /**
     * Runs `command` over `transport.stream` with a pty of the given size, passing the output on as it arrives and reading
     * the exit code from the in-band marker. Cancelling the calling coroutine stops the remote command; the run then returns
     * normally (with `cancelled` set) so the caller can still clean up its state.
     */
    suspend fun run(transport: SSHTransport, command: String, cols: Int, rows: Int, onEvent: (ActionStreamEvent) -> Unit): StreamedRun {
        val parser = StreamOutputParser()
        var transportError: String? = null
        var text = ""
        var cancelled = false
        fun keep(shown: String) {
            onEvent(ActionStreamEvent.Output(shown))
            if (text.toByteArray().size < 200_000) text += shown
        }
        try {
            transport.stream(StreamedCommand.wrap(command, cols, rows)).collect { chunk ->
                val shown = parser.push(chunk)
                if (shown.isNotEmpty()) keep(shown)
            }
        } catch (e: CancellationException) {
            cancelled = true
        } catch (e: Exception) {
            transportError = e.message ?: e.toString()
        }
        if (!currentCoroutineContext().isActive) cancelled = true
        return withContext(NonCancellable) {
            val (rest, exit) = parser.finish()
            if (rest.isNotEmpty()) keep(rest)
            onEvent(ActionStreamEvent.Finished(exit))
            StreamedRun(exit, cancelled, transportError, text)
        }
    }
}
