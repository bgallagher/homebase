package com.bgallagher.rackoon.core

/**
 * Turns streamed log chunks into lines. Chunks arrive split anywhere, and the remote pseudo-terminal ends lines with \r\n,
 * so this joins partial lines, normalises endings and caps memory.
 */
class LogBuffer(val maxLines: Int = 2000) {
    private val _lines = ArrayDeque<String>()
    val lines: List<String> get() = _lines.toList()

    /**
     * Every line ever appended, including those trimmed off the front. It only grows, so a view can say "N new lines" even
     * when the buffer is full and `lines.size` has stopped changing.
     */
    var totalAppended = 0
        private set
    private var partial = ""

    fun append(chunk: String) {
        val text = partial + chunk.replace("\r\n", "\n").replace("\r", "\n")
        val pieces = text.split('\n').toMutableList()
        partial = pieces.removeAt(pieces.lastIndex)
        // ssh prints this itself when the remote command ends; it is not part of the logs.
        val kept = pieces.filterNot { it.startsWith("Connection to ") && it.endsWith(" closed.") }
        _lines.addAll(kept)
        totalAppended += kept.size
        while (_lines.size > maxLines) _lines.removeFirst()
    }

    /** Everything received so far, including a final line that has no newline yet. */
    val text: String get() = (_lines + (if (partial.isEmpty()) emptyList() else listOf(partial))).joinToString("\n")
}

enum class LogLevel { ERROR, WARN, INFO, DEBUG }

/**
 * Finds a log line's level and timestamp so the UI can colour it. It only trusts explicit markers (`level=info`,
 * `"level":"warn"`, `[error]`, an upper-case `ERROR`), never prose, so a message that merely mentions "error" is not painted red.
 */
object LogLineParser {
    private val keyed = Regex("""\blevel["']?\s*[=:]\s*["']?([A-Za-z]+)""", RegexOption.IGNORE_CASE)
    private val bracketed = Regex("""\[(error|err|fatal|panic|critical|warn|warning|info|debug|trace)]""", RegexOption.IGNORE_CASE)
    private val shouting = Regex("""\b(ERROR|ERR|FATAL|PANIC|CRITICAL|WARN|WARNING|INFO|DEBUG|TRACE)\b""")
    private val leadingTimestamp = Regex(
        """^\s*(\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(\.\d+)?)""",
    )

    internal fun map(word: String): LogLevel? = when (word.lowercase()) {
        "error", "err", "fatal", "panic", "critical" -> LogLevel.ERROR
        "warn", "warning" -> LogLevel.WARN
        "info" -> LogLevel.INFO
        "debug", "trace" -> LogLevel.DEBUG
        else -> null
    }

    fun level(line: String): LogLevel? {
        for (re in listOf(keyed, bracketed, shouting)) {
            val m = re.find(line) ?: continue
            map(m.groupValues[1])?.let { return it }
        }
        return null
    }

    /** Number of leading characters that form a timestamp (0 if none). */
    fun timestampLength(line: String): Int = leadingTimestamp.find(line)?.range?.let { it.last + 1 } ?: 0
}
