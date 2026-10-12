package com.bgallagher.rackoon.core

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.CancellationException

sealed class RebootError(message: String) : Exception(message) {
    object NoSudo : RebootError("This user can't reboot the server without a password. Use root, or allow passwordless sudo for systemctl.")
    class Failed(detail: String) : RebootError(detail)
}

sealed class RebootOutcome {
    /** The server answered with a different boot id after `elapsedMillis`. */
    data class Back(val elapsedMillis: Long) : RebootOutcome()
    object TimedOut : RebootOutcome()
}

/**
 * Reboots a server and waits for it to come back. "Back" means a different kernel boot id, not just a successful connection:
 * for a couple of seconds after the command, the old system still answers.
 */
class RebootSession(private val transport: SSHTransport, private val policy: ActionPolicy = ActionPolicy()) {
    companion object {
        val bootIDCommand: String get() = SpecCommands.script("boot_id")
        val rebootCommand: String get() = SpecCommands.script("reboot")
        val intent: Intent get() = Intent("Reboot the server", rebootCommand, Risk.MUTATE)
    }

    private var previousBootID: String? = null
    private var startedAt: Long? = null

    fun confirm(): Confirmation = policy.confirm(intent)

    /**
     * Remembers the current boot id, then schedules the reboot. Returns once the command has been accepted; the connection
     * drops a couple of seconds later, so call [waitForReturn] next.
     */
    suspend fun reboot(confirmation: Confirmation?, now: () -> Long = System::currentTimeMillis) {
        policy.authorize(intent, confirmation)
        val before = transport.run(bootIDCommand, 10_000)
        val id = before.stdout.trim()
        if (before.exitCode != 0 || id.isEmpty()) throw RebootError.Failed("Could not read the server's boot id first: ${before.stderr.trim()}")
        val result = transport.run(rebootCommand, 15_000)
        if (result.exitCode == 5 || result.stdout.contains("##no-sudo")) throw RebootError.NoSudo
        if (result.exitCode != 0 || !result.stdout.contains("##rebooting")) {
            val detail = result.stderr.trim()
            throw RebootError.Failed(detail.ifEmpty { "The reboot command failed (exit ${result.exitCode})." })
        }
        previousBootID = id
        startedAt = now()
    }

    /**
     * Polls until the boot id differs from the one before the reboot. Connection errors are expected while the server is down
     * and are simply retried. `now` and `sleep` can be replaced so tests do not wait.
     */
    suspend fun waitForReturn(
        timeoutMillis: Long = 600_000, intervalMillis: Long = 4_000,
        now: () -> Long = System::currentTimeMillis, sleep: suspend (Long) -> Unit = { delay(it) },
    ): RebootOutcome {
        val previous = previousBootID ?: return RebootOutcome.TimedOut
        val start = startedAt ?: return RebootOutcome.TimedOut
        // The old system is still up for a moment; do not even ask until the reboot has had a chance to begin.
        sleep(minOf(intervalMillis, 3_000))
        while (now() - start < timeoutMillis) {
            if (!currentCoroutineContext().isActive) return RebootOutcome.TimedOut
            val result = try { transport.run(bootIDCommand, 10_000) } catch (e: CancellationException) { throw e } catch (e: Exception) { null }
            if (result != null && result.exitCode == 0) {
                val id = result.stdout.trim()
                if (id.isNotEmpty() && id != previous) return RebootOutcome.Back(now() - start)
            }
            sleep(intervalMillis)
        }
        return RebootOutcome.TimedOut
    }
}
