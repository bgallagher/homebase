package com.bgallagher.rackoon.core

/** A tiny growable byte buffer (ArrayList<Byte> would box every byte of terminal output). */
private class Bytes(capacity: Int = 256) {
    private var a = ByteArray(capacity)
    var size = 0
        private set

    fun add(b: Byte) { ensure(1); a[size++] = b }
    fun add(src: ByteArray) = add(src, 0, src.size)
    fun add(src: ByteArray, from: Int, to: Int) { val n = to - from; ensure(n); System.arraycopy(src, from, a, size, n); size += n }
    fun clear() { size = 0 }
    operator fun get(i: Int): Byte = a[i]
    fun removeLast(n: Int) { size -= n }
    fun toByteArray(): ByteArray = a.copyOf(size)
    private fun ensure(extra: Int) { if (size + extra > a.size) a = a.copyOf(maxOf(a.size * 2, size + extra)) }
}

/**
 * Rewrites a terminal's output byte stream to add colour (see [OutputHighlighter]) without ever changing what the terminal
 * would otherwise show: it only inserts SGR "set foreground" / "default foreground" pairs around matched text.
 *
 * Safety rules, all covered by tests:
 * - Escape sequences are copied through untouched, including OSC titles, charset selects and SGR.
 * - Nothing is coloured while a program has set its own colours (foreground, background or reverse video), so `ls --color`,
 *   shell prompts and syntax highlighters are left alone.
 * - Nothing is coloured on the alternate screen (vim, htop, less), tracked from DECSET 47/1047/1049.
 * - A match touching the end of a chunk, or continuing from the previous chunk's last token, is skipped: it may be part of a
 *   longer token. Typed echo therefore stays plain, and a token split across two reads is simply not coloured rather than
 *   coloured wrongly.
 * - An incomplete UTF-8 sequence at the end of a chunk is carried to the next call (only while enabled).
 */
class TerminalOutputFilter {
    /**
     * Controls only whether colour is *inserted*. Escape-sequence state (program colours, alternate screen) is tracked either
     * way, so switching on in the middle of a stream is immediately correct (for example while vim is open) and switching off
     * gives a byte-for-byte pass-through.
     */
    var isEnabled = true

    private enum class Mode { TEXT, ESC, ESC_INTERMEDIATE, CSI, OSC, OSC_ESC }

    private var mode = Mode.TEXT
    private val csi = StringBuilder()
    private var fgActive = false
    private var bgActive = false
    private var reverse = false
    private var altScreen = false
    private var carry = ByteArray(0)
    private var endsWithTokenByte = false

    private companion object {
        fun sgr(kind: HighlightKind): ByteArray {
            val code = when (kind) { HighlightKind.IP_ADDRESS -> "35"; HighlightKind.ERROR -> "31"; HighlightKind.WARNING -> "33"; HighlightKind.SUCCESS -> "32" }
            return "\u001B[${code}m".toByteArray()
        }

        val resetForeground = "\u001B[39m".toByteArray()

        fun isTokenByte(b: Byte): Boolean {
            val v = b.toInt() and 0xFF
            return (v in 0x30..0x39) || (v in 0x41..0x5A) || (v in 0x61..0x7A) || v == 0x2E || v == 0x3A || v == 0x25 || v == 0x5F || v >= 0x80
        }

        /** Number of trailing bytes forming an incomplete UTF-8 sequence (0 if the end is whole). */
        fun incompleteUtf8Tail(bytes: Bytes): Int {
            var i = bytes.size - 1
            var back = 0
            while (i >= 0 && back < 4) {
                val b = bytes[i].toInt() and 0xFF
                if (b and 0xC0 == 0x80) { i--; back++; continue } // continuation byte
                val needed = if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1
                return if (needed > back + 1) back + 1 else 0
            }
            return 0
        }
    }

    fun process(input: ByteArray): ByteArray {
        // Fast path for the common "off" case: with highlighting disabled and no escape byte in this chunk (and none
        // half-parsed from the last one), nothing can change our state or the output, so hand the bytes straight back.
        if (!isEnabled && mode == Mode.TEXT && carry.isEmpty() && input.none { it == 0x1B.toByte() }) {
            if (input.isNotEmpty()) {
                val last = input.last().toInt() and 0xFF
                endsWithTokenByte = if (!(last < 0x20 || last == 0x7F)) isTokenByte(input.last()) else false
            }
            return input
        }
        val data = carry + input
        carry = ByteArray(0)
        val out = Bytes(data.size + 32)
        val run = Bytes()

        for (byte in data) {
            val b = byte.toInt() and 0xFF
            when (mode) {
                Mode.TEXT -> when {
                    b == 0x1B -> { flush(run, out, atChunkEnd = false); out.add(byte); mode = Mode.ESC }
                    b < 0x20 || b == 0x7F -> { flush(run, out, atChunkEnd = false); out.add(byte); endsWithTokenByte = false }
                    else -> run.add(byte)
                }
                Mode.ESC -> {
                    out.add(byte)
                    when (b) {
                        0x5B -> { mode = Mode.CSI; csi.setLength(0) }
                        0x5D, 0x50, 0x58, 0x5E, 0x5F -> mode = Mode.OSC // OSC, DCS, SOS, PM, APC: run to a string terminator
                        in 0x20..0x2F -> mode = Mode.ESC_INTERMEDIATE // e.g. ESC ( B
                        0x63 -> { resetStyleState(); mode = Mode.TEXT } // RIS
                        else -> mode = Mode.TEXT
                    }
                }
                Mode.ESC_INTERMEDIATE -> { out.add(byte); if (b !in 0x20..0x2F) mode = Mode.TEXT }
                Mode.CSI -> {
                    out.add(byte)
                    if (b in 0x40..0x7E) { finishCsi(b); mode = Mode.TEXT } else csi.append(b.toChar())
                }
                Mode.OSC -> { out.add(byte); if (b == 0x07) mode = Mode.TEXT else if (b == 0x1B) mode = Mode.OSC_ESC }
                Mode.OSC_ESC -> { out.add(byte); mode = if (b == 0x5C) Mode.TEXT else Mode.OSC } // ESC \ ends it; any other byte is still inside the string
            }
        }

        // Keep an incomplete trailing UTF-8 sequence for the next call instead of splitting a character. Only hold bytes back
        // when we might rewrite them; a disabled filter passes everything straight through.
        val tail = if (isEnabled) incompleteUtf8Tail(run) else 0
        if (tail > 0) {
            val all = run.toByteArray()
            carry = all.copyOfRange(all.size - tail, all.size)
            run.removeLast(tail)
        }
        flush(run, out, atChunkEnd = true)
        return out.toByteArray()
    }

    /** Call once when the stream ends: returns any bytes still held back (an incomplete UTF-8 tail), unmodified. */
    fun finish(): ByteArray {
        val held = carry
        carry = ByteArray(0)
        return held
    }

    // MARK: text runs

    private fun flush(run: Bytes, out: Bytes, atChunkEnd: Boolean) {
        if (run.size == 0) return
        val bytes = run.toByteArray()
        run.clear()
        val wasAdjacent = endsWithTokenByte
        endsWithTokenByte = isTokenByte(bytes[bytes.size - 1])

        val text = if (isEnabled && !altScreen && !fgActive && !bgActive && !reverse) decodeStrict(bytes) else null
        if (text == null) { out.add(bytes); return }
        var cursor = 0
        for (span in OutputHighlighter.spans(text)) {
            if (atChunkEnd && span.end == bytes.size) continue // may continue in the next chunk
            if (wasAdjacent && span.start == 0) continue // may continue the previous chunk's token
            out.add(bytes, cursor, span.start)
            out.add(sgr(span.kind))
            out.add(bytes, span.start, span.end)
            out.add(resetForeground)
            cursor = span.end
        }
        out.add(bytes, cursor, bytes.size)
    }

    /** The text if the bytes are valid UTF-8, otherwise null (then the run is passed through unchanged). */
    private fun decodeStrict(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (_: java.nio.charset.CharacterCodingException) {
        null
    }

    // MARK: escape sequence state

    private fun resetStyleState() { fgActive = false; bgActive = false; reverse = false; altScreen = false }

    private fun finishCsi(final: Int) {
        val text = csi.toString()
        when (final) {
            'm'.code -> if (!(text.startsWith("?") || text.startsWith(">") || text.startsWith("<") || text.startsWith("="))) applySgr(text)
            'h'.code, 'l'.code -> {
                if (!text.startsWith("?")) return
                for (mode in text.drop(1).split(';').filter { it.isNotEmpty() }) {
                    if (mode == "47" || mode == "1047" || mode == "1049") altScreen = final == 'h'.code
                }
            }
        }
    }

    private fun applySgr(params: String) {
        val parts = if (params.isEmpty()) listOf("0") else params.split(';')
        var i = 0
        while (i < parts.size) {
            // "38:2::r:g:b" style sub-parameters: only the leading code matters here.
            val code = parts[i].split(':').first().toIntOrNull() ?: 0
            when (code) {
                0 -> { fgActive = false; bgActive = false; reverse = false }
                7 -> reverse = true
                27 -> reverse = false
                in 30..37, in 90..97 -> fgActive = true
                39 -> fgActive = false
                in 40..47, in 100..107 -> bgActive = true
                49 -> bgActive = false
                38, 48 -> {
                    if (code == 38) fgActive = true else bgActive = true
                    if (!parts[i].contains(':')) {
                        val kind = if (i + 1 < parts.size) parts[i + 1].toIntOrNull() else null
                        i += if (kind == 5) 2 else if (kind == 2) 4 else 0 // skip the colour's own parameters
                    }
                }
            }
            i++
        }
    }
}
