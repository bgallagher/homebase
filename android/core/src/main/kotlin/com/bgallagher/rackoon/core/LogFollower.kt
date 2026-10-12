package com.bgallagher.rackoon.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** One log line and the container (its compose service name) it came from. */
class LogEntry(val id: Int, val source: String, val line: String) {
    /** Only explicit markers count (see [LogLineParser]); null when the line says nothing about its level. */
    val level: LogLevel? = LogLineParser.level(line)
    val parts: LogParts by lazy(LazyThreadSafetyMode.NONE) { LogParts.of(line, level) }
}

/** What a log row shows: the time, the level and the message with those two taken out of it. */
data class LogParts(val time: String?, val level: LogLevel?, val message: String) {
    companion object {
        private val leadingLevel = Regex("""^(\[(error|err|fatal|panic|critical|warn|warning|info|debug|trace)]|(error|err|fatal|panic|critical|warn|warning|info|debug|trace):?|level=["']?[A-Za-z]+["']?)\s+""", RegexOption.IGNORE_CASE)

        fun of(line: String, level: LogLevel?): LogParts {
            val tsLength = LogLineParser.timestampLength(line)
            val time = if (tsLength > 0) line.substring(0, tsLength).trim() else null
            var rest = line.substring(tsLength).trimStart()
            // The level is shown on its own, so drop it from the start of the message (it stays when it is in the middle of one).
            if (level != null) leadingLevel.find(rest)?.let { rest = rest.substring(it.range.last + 1).trimStart() }
            return LogParts(time, level, rest)
        }
    }
}

/** The container name log lines are tagged with: the compose service name, else the container name. */
val DockerContainer.logSource: String get() = service ?: name

data class LogsState(
    /** Merged across the followed containers in arrival order, capped. Updated in batches so a chatty container cannot flood the UI. */
    val entries: List<LogEntry> = emptyList(),
    /** Lines received since following began (not capped), for "N new lines" while scrolled away. */
    val received: Int = 0,
    val containers: List<DockerContainer> = emptyList(),
    val live: Boolean = false,
    val error: String? = null,
)

/**
 * Follows the logs of a stack's containers at once, merged. Each container gets its own `docker logs -f` on its own pty
 * connection (cancelling sends Ctrl-C, so nothing is left running on the server). Mirrors `DockerModel.showLogs` on the Mac.
 */
class LogFollower(
    private val transport: SSHTransport,
    private val maxEntries: Int = 2000,
    private val flushMillis: Long = 100,
) {
    private val _state = MutableStateFlow(LogsState())
    val state: StateFlow<LogsState> = _state.asStateFlow()

    private val lock = Any()
    private var pending = ArrayList<LogEntry>()
    private var nextId = 0
    private var flushScheduled = false
    private var generation = 0
    private var job: Job? = null

    /** Starts following these containers. Does nothing if exactly these are already being followed; otherwise restarts. */
    fun follow(scope: CoroutineScope, containers: List<DockerContainer>) {
        if (containers.isEmpty() || containers.map { it.id } == _state.value.containers.map { it.id } && job?.isActive == true) return
        stop()
        val gen = synchronized(lock) { ++generation }
        _state.value = LogsState(containers = containers, live = true)
        val commands = containers.mapNotNull { c -> DockerSession.logsCommand(c.id)?.let { c to it } }
        job = scope.launch {
            val followers = commands.map { (container, command) -> launch { followOne(scope, container, command, gen) } }
            followers.forEach { it.join() }
            if (synchronized(lock) { generation == gen }) _state.update { it.copy(live = false) }
        }
    }

    private suspend fun followOne(scope: CoroutineScope, container: DockerContainer, command: String, gen: Int) {
        val buffer = LogBuffer()
        var seen = 0
        try {
            transport.stream(command).collect { chunk ->
                synchronized(lock) { if (generation != gen) return@collect }
                buffer.append(chunk)
                val fresh = buffer.totalAppended - seen
                seen = buffer.totalAppended
                val added = buffer.lines.takeLast(fresh)
                synchronized(lock) {
                    if (generation != gen) return@collect
                    for (line in added) pending.add(LogEntry(nextId++, container.logSource, line))
                }
                scheduleFlush(scope, gen)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (synchronized(lock) { generation == gen }) _state.update { it.copy(error = e.message ?: e.toString()) }
        }
    }

    private fun scheduleFlush(scope: CoroutineScope, gen: Int) {
        synchronized(lock) { if (flushScheduled) return; flushScheduled = true }
        scope.launch {
            delay(flushMillis)
            val batch = synchronized(lock) {
                flushScheduled = false
                if (generation != gen) return@launch
                pending.also { pending = ArrayList() }
            }
            _state.update { s ->
                val merged = if (s.entries.size + batch.size > maxEntries) (s.entries + batch).takeLast(maxEntries) else s.entries + batch
                s.copy(entries = merged, received = s.received + batch.size)
            }
        }
    }

    /** Stops following (Ctrl-C reaches every remote `docker logs -f`) and clears what was collected. */
    fun stop() {
        synchronized(lock) { generation++; pending = ArrayList(); flushScheduled = false }
        job?.cancel()
        job = null
        _state.value = LogsState()
    }
}

/** Filtering for the log view: which container, which level, which text. Pure, so it is tested without a screen. */
object LogView {
    fun filtered(entries: List<LogEntry>, focus: String? = null, level: LogLevel? = null, search: String = ""): List<LogEntry> {
        val needle = search.trim()
        return entries.filter { e ->
            (focus == null || e.source == focus) && (level == null || e.level == level) &&
                (needle.isEmpty() || e.line.contains(needle, ignoreCase = true))
        }
    }

    /** Counts for the level chips, from the lines of the focused container (before the level and search filters). */
    fun counts(entries: List<LogEntry>, focus: String? = null): Map<LogLevel?, Int> {
        val scoped = if (focus == null) entries else entries.filter { it.source == focus }
        return scoped.groupingBy { it.level }.eachCount() + (null to scoped.size)   // null = All
    }

    /** What Copy puts on the clipboard: the visible lines, tagged with their container when several are mixed. */
    fun text(entries: List<LogEntry>, showSource: Boolean): String = entries.joinToString("\n") { if (showSource) "${it.source} | ${it.line}" else it.line }
}
