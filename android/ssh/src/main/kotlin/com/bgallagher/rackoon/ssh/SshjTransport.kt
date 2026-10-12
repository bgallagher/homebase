package com.bgallagher.rackoon.ssh

import com.bgallagher.rackoon.core.CommandResult
import com.bgallagher.rackoon.core.SSHTransport
import com.bgallagher.rackoon.core.SessionEnd
import com.bgallagher.rackoon.core.Utf8Chunker
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.SecurityUtils
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.transport.TransportException
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.userauth.UserAuthException
import net.schmizz.sshj.userauth.method.AuthNone
import net.schmizz.sshj.userauth.password.PasswordUtils
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.PublicKey
import java.util.concurrent.TimeUnit

/** Checks the presented key against [KnownHosts] and remembers the verdict, so a refusal can be turned into a precise error. */
internal class StrictHostKeyVerifier(private val knownHosts: KnownHosts) : HostKeyVerifier {
    @Volatile var verdict: HostKeyVerdict? = null

    override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
        val result = knownHosts.verdict(hostname, port, HostKeyInfo.from(key))
        verdict = result
        return result is HostKeyVerdict.Trusted
    }

    // Prefer the key type already trusted, so a server that offers several does not look "changed" because it picked another.
    override fun findExistingAlgorithms(hostname: String, port: Int): List<String> = listOfNotNull(knownHosts.lookup(hostname, port)?.keyType)
}

private fun SSHClient.quietlyDisconnect() {
    try { disconnect() } catch (_: Exception) {}
}

/** Opens and authenticates one connection. Blocking: call from an IO dispatcher. Retries once after a connect timeout (the first connection after Tailscale idled took over 10 s in the spike). */
internal fun openClient(endpoint: SshEndpoint, knownHosts: KnownHosts, connectTimeoutMillis: Long): SSHClient {
    SshProviders.install()
    var lastTimeout: SshException.Unreachable? = null
    for (attempt in 0..1) {
        val verifier = StrictHostKeyVerifier(knownHosts)
        val ssh = SSHClient()
        ssh.addHostKeyVerifier(verifier)
        ssh.connectTimeout = connectTimeoutMillis.toInt()
        try {
            ssh.connect(endpoint.host, endpoint.port)
            ssh.connection.keepAlive.keepAliveInterval = 15
            authenticate(ssh, endpoint)
            return ssh
        } catch (e: Exception) {
            ssh.quietlyDisconnect()
            when (val v = verifier.verdict) {
                is HostKeyVerdict.Unknown -> throw SshException.HostKeyUnknown(v.presented)
                is HostKeyVerdict.Changed -> throw SshException.HostKeyChanged(v.trusted, v.presented)
                else -> {}
            }
            val mapped = map(e)
            if (attempt == 0 && e is SocketTimeoutException && mapped is SshException.Unreachable) { lastTimeout = mapped; continue }
            throw mapped
        }
    }
    throw lastTimeout ?: SshException.Unreachable("timed out")
}

private fun authenticate(ssh: SSHClient, endpoint: SshEndpoint) {
    when (val auth = endpoint.auth) {
        SshAuth.TailscaleNone -> ssh.auth(endpoint.user, AuthNone())
        is SshAuth.Password -> ssh.authPassword(endpoint.user, auth.password)
        is SshAuth.PrivateKey -> {
            val finder = auth.passphrase?.let { PasswordUtils.createOneOff(it.toCharArray()) }
            ssh.authPublickey(endpoint.user, ssh.loadKeys(auth.pem, null, finder))
        }
    }
}

private fun map(e: Throwable): SshException = when (e) {
    is SshException -> e
    is UserAuthException -> SshException.AuthFailed(e.message ?: "no accepted method", e)
    is SocketTimeoutException -> SshException.Unreachable("timed out", e)
    is ConnectException, is NoRouteToHostException, is UnknownHostException -> SshException.Unreachable(e.message ?: e.javaClass.simpleName, e)
    is TransportException -> SshException.ConnectionLost(e.message ?: "transport error", e)
    is IOException -> SshException.ConnectionLost(e.message ?: "I/O error", e)
    else -> SshException.ConnectionLost(e.message ?: e.javaClass.simpleName, e)
}

/**
 * Reads a server's host key without signing in: connects, takes the key it presents and disconnects before any credentials
 * could be sent. The caller shows its fingerprint and, if the user agrees, passes it to [KnownHosts.trust].
 */
suspend fun scanHostKey(host: String, port: Int = 22, connectTimeoutMillis: Long = 30_000): HostKeyInfo = withContext(Dispatchers.IO) {
    SshProviders.install()
    var captured: HostKeyInfo? = null
    val ssh = SSHClient()
    ssh.addHostKeyVerifier(object : HostKeyVerifier {
        override fun verify(hostname: String, port: Int, key: PublicKey): Boolean { captured = HostKeyInfo.from(key); return true }
        override fun findExistingAlgorithms(hostname: String, port: Int): List<String> = emptyList()
    })
    ssh.connectTimeout = connectTimeoutMillis.toInt()
    try {
        ssh.connect(host, port)
        captured ?: throw SshException.ConnectionLost("the server did not present a host key")
    } catch (e: Exception) {
        throw map(e)
    } finally {
        ssh.quietlyDisconnect()
    }
}

/** A terminal session: a shell on a pty that can be resized. */
interface ShellSession {
    /** Everything the remote side prints (stdout and stderr share the pty), as raw bytes for the terminal emulator. */
    val output: Flow<ByteArray>

    suspend fun write(bytes: ByteArray)

    suspend fun resize(cols: Int, rows: Int)

    /** Waits until the session is over and says why (so the app can decide whether to reconnect). */
    suspend fun awaitEnd(): SessionEnd

    /** Ends the session now (the user closed it). */
    suspend fun close()
}

/**
 * sshj behind core's [SSHTransport]. One long-lived authenticated connection serves `run` (a channel per command, like a
 * ControlMaster) and terminal shells; `stream` uses its own connection with a pty, because stopping a stream must send Ctrl-C
 * through the pty (closing alone leaves the remote command running; proven against the real server).
 */
class SshjTransport(
    private val endpoint: SshEndpoint,
    private val knownHosts: KnownHosts,
    private val connectTimeoutMillis: Long = 30_000,
) : SSHTransport, AutoCloseable {
    private val connectLock = Mutex()
    @Volatile private var client: SSHClient? = null

    private suspend fun connection(): SSHClient = connectLock.withLock {
        client?.takeIf { it.isConnected && it.isAuthenticated } ?: withContext(Dispatchers.IO) {
            client?.quietlyDisconnect()
            client = null
            openClient(endpoint, knownHosts, connectTimeoutMillis).also { client = it }
        }
    }

    private fun invalidate(ssh: SSHClient) {
        if (client === ssh) client = null
        ssh.quietlyDisconnect()
    }

    /** Connects now (host key, authentication) without running anything. Used by "Test connection". */
    suspend fun connect() { connection() }

    override suspend fun run(command: String, timeoutMillis: Long): CommandResult {
        var retried = false
        while (true) {
            val ssh = connection()
            try {
                return exec(ssh, command, timeoutMillis)
            } catch (e: SshException.Timeout) {
                throw e
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The connection died under us (the network changed, the server rebooted): reconnect once and try again.
                invalidate(ssh)
                if (retried) throw map(e)
                retried = true
            }
        }
    }

    private suspend fun exec(ssh: SSHClient, command: String, timeoutMillis: Long): CommandResult = withContext(Dispatchers.IO) {
        val session = ssh.startSession()
        try {
            val cmd = session.exec(command)
            coroutineScope {
                // Blocking reads cannot be cancelled, so the session is closed in `finally` to free them on timeout or cancel.
                val out = async(Dispatchers.IO) { runCatching { cmd.inputStream.readBytes() }.getOrDefault(ByteArray(0)) }
                val err = async(Dispatchers.IO) { runCatching { cmd.errorStream.readBytes() }.getOrDefault(ByteArray(0)) }
                try {
                    withTimeout(timeoutMillis) {
                        val o = out.await()
                        val e = err.await()
                        cmd.join(5, TimeUnit.SECONDS)
                        CommandResult(String(o, Charsets.UTF_8), String(e, Charsets.UTF_8), cmd.exitStatus ?: -1)
                    }
                } catch (e: TimeoutCancellationException) {
                    throw SshException.Timeout(timeoutMillis)
                } finally {
                    runCatching { session.close() }
                }
            }
        } finally {
            runCatching { session.close() }
        }
    }

    override fun stream(command: String): Flow<String> = channelFlow {
        val (ssh, session, cmd) = withContext(Dispatchers.IO) {
            val ssh = openClient(endpoint, knownHosts, connectTimeoutMillis)
            try {
                val session = ssh.startSession()
                session.allocateDefaultPTY()
                Triple(ssh, session, session.exec(command))
            } catch (e: Exception) {
                ssh.quietlyDisconnect()
                throw map(e)
            }
        }
        val reader = launch(Dispatchers.IO) {
            val chunker = Utf8Chunker()
            val buf = ByteArray(8192)
            try {
                while (true) {
                    val n = cmd.inputStream.read(buf)
                    if (n < 0) break
                    val text = chunker.push(buf.copyOf(n))
                    if (text.isNotEmpty()) send(text)
                }
                val rest = chunker.finish()
                if (rest.isNotEmpty()) send(rest)
            } catch (_: IOException) {
                // the channel was closed (cancel) or the connection dropped: the stream just ends
            }
        }
        try {
            reader.join()
        } finally {
            withContext(NonCancellable + Dispatchers.IO) {
                // Stop the remote command the way a terminal does: Ctrl-C through the pty, a grace period, then close.
                runCatching { cmd.outputStream.write(3); cmd.outputStream.flush() }
                withTimeoutOrNull(2_000) { reader.join() }
                runCatching { session.close() }
                ssh.quietlyDisconnect()
            }
        }
    }

    /** Opens a terminal: a shell on a pty of the given size (take it from the emulator's measured size). */
    suspend fun openShell(cols: Int, rows: Int): ShellSession {
        val ssh = connection()
        return withContext(Dispatchers.IO) {
            try {
                val session = ssh.startSession()
                session.allocatePTY("xterm-256color", cols, rows, 0, 0, emptyMap())
                SshjShell(ssh, session, session.startShell())
            } catch (e: Exception) {
                invalidate(ssh)
                throw map(e)
            }
        }
    }

    override fun close() {
        client?.quietlyDisconnect()
        client = null
    }
}

private class SshjShell(
    private val ssh: SSHClient,
    private val session: Session,
    private val shell: Session.Shell,
) : ShellSession {
    private val channel = Channel<ByteArray>(Channel.UNLIMITED)
    private val writeLock = Mutex()
    @Volatile private var closedByUser = false
    private val scope = CoroutineScope(Dispatchers.IO)
    private val reader = scope.launch {
        val buf = ByteArray(16 * 1024)
        try {
            while (true) {
                val n = shell.inputStream.read(buf)
                if (n < 0) break
                channel.send(buf.copyOf(n))
            }
        } catch (_: IOException) {
        } finally {
            channel.close()
        }
    }

    override val output: Flow<ByteArray> = channel.receiveAsFlow()

    override suspend fun write(bytes: ByteArray) {
        withContext(Dispatchers.IO) {
            writeLock.withLock {
                try {
                    shell.outputStream.write(bytes)
                    shell.outputStream.flush()
                } catch (_: IOException) {
                    // the session is ending; awaitEnd() reports why
                }
            }
        }
    }

    override suspend fun resize(cols: Int, rows: Int) {
        withContext(Dispatchers.IO) { runCatching { shell.changeWindowDimensions(cols, rows, 0, 0) } }
    }

    // sshj's channel object is also the command channel, which is where the shell's exit status lives.
    private fun exitStatus(): Int? = (shell as? Session.Command)?.exitStatus

    override suspend fun awaitEnd(): SessionEnd {
        reader.join()
        return when {
            closedByUser -> SessionEnd.ClosedByUser
            exitStatus() != null -> SessionEnd.RemoteExit(exitStatus()!!)
            !ssh.isConnected -> SessionEnd.ConnectionLost
            else -> SessionEnd.ConnectionLost // the channel closed without a status: treat it as a dropped link
        }
    }

    override suspend fun close() {
        closedByUser = true
        withContext(Dispatchers.IO) { runCatching { session.close() } }
    }
}
