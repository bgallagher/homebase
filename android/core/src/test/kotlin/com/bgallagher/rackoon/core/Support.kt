package com.bgallagher.rackoon.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/** Replays canned output; records what it was asked to run. */
class FakeTransport(responses: List<Result<CommandResult>> = emptyList()) : SSHTransport {
    private val queue = ArrayDeque(responses)
    val commands = mutableListOf<String>()

    /** What `stream` emits, chunk by chunk, before finishing; and what it was asked to run. */
    var streamChunks: List<String> = emptyList()
    val streamedCommands = mutableListOf<String>()

    @Synchronized private fun next(command: String): Result<CommandResult> {
        commands += command
        if (queue.isEmpty()) return Result.success(CommandResult("", exitCode = 1))
        return if (queue.size > 1) queue.removeFirst() else queue.first()
    }

    override suspend fun run(command: String, timeoutMillis: Long): CommandResult = next(command).getOrThrow()

    override fun stream(command: String): Flow<String> {
        synchronized(this) { streamedCommands += command }
        val chunks = streamChunks
        return flow { chunks.forEach { emit(it) } }
    }
}

fun ok(stdout: String, stderr: String = "", exitCode: Int = 0): Result<CommandResult> = Result.success(CommandResult(stdout, stderr, exitCode))

class Collector {
    val events = mutableListOf<ActionStreamEvent>()
    fun add(e: ActionStreamEvent) { events += e }
    val text: String get() = events.filterIsInstance<ActionStreamEvent.Output>().joinToString("") { it.text }
}
