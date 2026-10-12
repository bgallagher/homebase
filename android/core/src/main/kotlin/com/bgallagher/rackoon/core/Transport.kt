package com.bgallagher.rackoon.core

import kotlinx.coroutines.flow.Flow

data class CommandResult(val stdout: String, val stderr: String = "", val exitCode: Int = 0)

/**
 * How Core talks to a server. Implemented by the sshj transport on Android and by fakes in tests. Core never imports an SSH
 * library or Android.
 */
interface SSHTransport {
    /** Runs one command without a terminal and returns its output, or throws if it cannot be run or times out. */
    suspend fun run(command: String, timeoutMillis: Long): CommandResult

    /**
     * Streams a command's output as it arrives (the command runs on its own connection with a pty). Cancelling the collector
     * must send Ctrl-C through the pty before closing, so the remote process ends (closing alone leaves it running).
     */
    fun stream(command: String): Flow<String>
}
