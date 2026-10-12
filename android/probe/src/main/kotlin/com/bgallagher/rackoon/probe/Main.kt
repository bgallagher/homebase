package com.bgallagher.rackoon.probe

import com.bgallagher.rackoon.core.ActionStreamEvent
import com.bgallagher.rackoon.core.ServerSession
import com.bgallagher.rackoon.core.SessionEnd
import com.bgallagher.rackoon.core.StreamRunner
import com.bgallagher.rackoon.ssh.HostKeyInfo
import com.bgallagher.rackoon.ssh.InMemoryKnownHosts
import com.bgallagher.rackoon.ssh.SshAuth
import com.bgallagher.rackoon.ssh.SshEndpoint
import com.bgallagher.rackoon.ssh.SshException
import com.bgallagher.rackoon.ssh.SshjTransport
import com.bgallagher.rackoon.ssh.scanHostKey
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.system.exitProcess

/**
 * Real-server checks, like apple's rackoon-probe. Usage: probe <host> <check> [user]
 *   overview       connect (Tailscale SSH none auth), poll the overview twice, print what was parsed
 *   hostkey        unknown, trusted and changed keys are told apart and nothing is trusted without asking
 *   stream-check   a streamed `docker logs -f` leaves no process behind on the server after it is cancelled
 *   stream-marker  a command run through StreamRunner reports its real exit code over a real pty
 *   shell-check    a shell opens at the requested size, follows a resize and ends with the shell's own status
 * Every check only reads, or works on nothing but its own temporary process; none changes the server.
 */
fun main(args: Array<String>) {
    if (args.size < 2) {
        System.err.println("usage: probe <host> <overview|hostkey|stream-check|stream-marker|shell-check> [user]")
        exitProcess(2)
    }
    val host = args[0]
    val check = args[1]
    val user = args.getOrNull(2) ?: "root"
    val failures = mutableListOf<String>()
    fun ok(what: String) = println("  ok    $what")
    fun fail(what: String) { println("  FAIL  $what"); failures += what }
    fun expect(what: String, condition: Boolean) = if (condition) ok(what) else fail(what)

    runBlocking {
        val known = InMemoryKnownHosts()
        println("probe $check on $user@$host")
        val key = scanHostKey(host)
        println("  host key ${key.algorithmLabel} ${key.fingerprint}")
        known.trust(host, 22, key) // a throwaway store: this run trusts what it just scanned, and says so above
        val transport = SshjTransport(SshEndpoint(host, 22, user, SshAuth.TailscaleNone), known)
        try {
            when (check) {
                "overview" -> {
                    val t0 = System.nanoTime()
                    transport.connect()
                    println("  connected in ${(System.nanoTime() - t0) / 1_000_000} ms")
                    val session = ServerSession(transport)
                    val t1 = System.nanoTime()
                    session.refresh()
                    val first = session.state.value
                    println("  first poll ${(System.nanoTime() - t1) / 1_000_000} ms")
                    expect("first poll parsed", first.overview != null && first.error == null)
                    delay(2_000)
                    val t2 = System.nanoTime()
                    session.refresh()
                    println("  second poll ${(System.nanoTime() - t2) / 1_000_000} ms")
                    val s = session.state.value
                    val o = s.overview
                    if (o != null) {
                        println("  ${o.hostname}: ${o.os.prettyName}, ${o.cores} cores, load ${o.load1}, memory ${o.memory.usedBytes / 1_048_576} / ${o.memory.totalBytes / 1_048_576} MiB")
                        println("  ip ${o.ipAddress} tailscale ${o.tailscaleIP}, disks ${o.disks.map { "${it.mount} ${it.usePercent}%" }}, attention ${s.attention.map { it.id }}")
                    }
                    expect("cpu percent from two polls", s.cpuPercent != null)
                }

                "hostkey" -> {
                    val strict = InMemoryKnownHosts()
                    val unknown = runCatching { SshjTransport(SshEndpoint(host, 22, user, SshAuth.TailscaleNone), strict).connect() }.exceptionOrNull()
                    expect("an untrusted server is refused with its fingerprint", unknown is SshException.HostKeyUnknown && unknown.presented.fingerprint == key.fingerprint)
                    strict.trust(host, 22, key)
                    val trusted = runCatching { SshjTransport(SshEndpoint(host, 22, user, SshAuth.TailscaleNone), strict).connect() }
                    expect("a trusted server connects", trusted.isSuccess)
                    val tampered = InMemoryKnownHosts()
                    tampered.trust(host, 22, HostKeyInfo(key.keyType, key.blob.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }))
                    val changed = runCatching { SshjTransport(SshEndpoint(host, 22, user, SshAuth.TailscaleNone), tampered).connect() }.exceptionOrNull()
                    expect("a different key is blocked, not offered", changed is SshException.HostKeyChanged && changed.presented.fingerprint == key.fingerprint)
                }

                "stream-check" -> {
                    val id = transport.run("docker ps -q | head -1", 10_000).stdout.trim()
                    if (id.isEmpty()) { println("  no running container to follow; skipped"); return@runBlocking }
                    val marker = "docker logs -f --tail 7 $id"
                    val received = StringBuilder()
                    val job = launch { transport.stream(marker).collect { received.append(it) } }
                    delay(3_000)
                    expect("log output arrived", received.isNotEmpty())
                    job.cancel()
                    job.join()
                    delay(1_500)
                    val left = transport.run("pgrep -af 'docker logs -f --tail 7 ' | grep -v pgrep | wc -l", 10_000).stdout.trim()
                    expect("no follower left on the server after cancel (found $left)", left == "0")
                    if (left != "0") transport.run("pkill -f 'docker logs -f --tail 7 '", 10_000)
                }

                "stream-marker" -> {
                    val events = mutableListOf<ActionStreamEvent>()
                    val run = StreamRunner.run(transport, "echo hello from the pty; exit 3", 100, 24) { events += it }
                    expect("output shown", run.text.contains("hello from the pty"))
                    expect("the command's own exit code (3) comes back through the marker", run.exitCode == 3)
                    expect("the marker line itself is not shown", !run.text.contains("rackoon-exit"))
                    val ok = StreamRunner.run(transport, "true", 80, 24) {}
                    expect("exit 0 is success", ok.succeeded)
                }

                "shell-check" -> {
                    val shell = transport.openShell(80, 24)
                    val seen = StringBuilder()
                    val reader = async { shell.output.collect { seen.append(String(it, Charsets.UTF_8)) } }
                    suspend fun waitFor(text: String): Boolean = runCatching { withTimeout(10_000) { while (!seen.contains(text)) delay(50) } }.isSuccess
                    // the shell echoes what is typed, so wait for text that only the OUTPUT contains (the sum is computed by the remote shell)
                    shell.write("stty size; echo DONE\$((1+1))\n".toByteArray())
                    expect("the shell answers", waitFor("DONE2"))
                    expect("opened at 24 rows x 80 columns", seen.contains("24 80"))
                    shell.resize(100, 30)
                    delay(300)
                    shell.write("stty size; echo DONE\$((1+2))\n".toByteArray())
                    expect("answers after the resize", waitFor("DONE3"))
                    expect("resized to 30 rows x 100 columns", seen.contains("30 100"))
                    if (failures.isNotEmpty()) println("  what the shell printed: ${seen.toString().replace("\u001B", "<ESC>").replace("\r", "<CR>").replace("\n", "<LF>").takeLast(700)}")
                    shell.write("exit\n".toByteArray())
                    val end = withTimeout(10_000) { shell.awaitEnd() }
                    reader.await()
                    expect("ends with the shell's own status (got $end)", end == SessionEnd.RemoteExit(0))
                }

                else -> { System.err.println("unknown check $check"); exitProcess(2) }
            }
        } finally {
            transport.close()
        }
    }
    if (failures.isEmpty()) println("PASS") else { println("FAILED: ${failures.size}"); exitProcess(1) }
}
