package com.bgallagher.rackoon.probe

import com.bgallagher.rackoon.core.ActionStreamEvent
import com.bgallagher.rackoon.core.Bookmark
import com.bgallagher.rackoon.core.BookmarkEditor
import com.bgallagher.rackoon.core.BookmarkPlan
import com.bgallagher.rackoon.core.DockerContainer
import com.bgallagher.rackoon.core.DockerStack
import com.bgallagher.rackoon.core.EditableFile
import com.bgallagher.rackoon.core.FileEdit
import com.bgallagher.rackoon.core.SaveOutcome
import com.bgallagher.rackoon.core.StackFileSession
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
 *   bookmark-test  REAL label edits and saves (server-side compose check, .rackoon.bak, the changed-on-server guard, removal) on a
 *                  throwaway stack under /tmp that it creates and removes. It never touches your own stacks.
 *   sandbox-up     REAL: creates ONE harmless stack, /tmp/rackoon-sandbox (project rackoonsandbox: a hello-world web page on
 *                  127.0.0.1:18080 and redis), and starts it, so the phone's Docker actions can be tried on it
 *   sandbox-down   REAL: stops and removes exactly that stack and its folder. Neither touches anything else.
 * Every other check only reads, or works on nothing but its own temporary process; none changes the server.
 */
fun main(args: Array<String>) {
    if (args.size < 2) {
        System.err.println("usage: probe <host> <overview|hostkey|stream-check|stream-marker|shell-check|bookmark-test|sandbox-up|sandbox-down> [user]")
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

                "bookmark-test" -> {
                    val id = System.currentTimeMillis()
                    val dir = "/tmp/rackoon-probe-bm-$id"
                    val project = "rackoonprobebm$id"
                    val file = "$dir/compose.yaml"
                    val original = "# keep me\nservices:\n  web:\n    image: nginx:alpine\n    restart: always\n"
                    suspend fun sh(cmd: String) = transport.run(cmd, 60_000)
                    try {
                        val b64 = java.util.Base64.getEncoder().encodeToString(original.toByteArray())
                        val setup = sh("mkdir -p $dir && echo $b64 | base64 -d > $file && chmod 640 $file")
                        expect("throwaway stack created under /tmp", setup.exitCode == 0)
                        expect("docker compose is available", sh("docker compose version").exitCode == 0)
                        val container = DockerContainer(
                            id = "abcdef012345", name = "$project-web-1", image = "nginx:alpine", state = "running", health = "none", status = "Up",
                            ports = emptyList(), project = project, service = "web", workingDir = dir, configFile = file, configFiles = listOf(file),
                        )
                        val stack = DockerStack(project, dir, file, listOf(file), listOf(container), false)
                        val session = StackFileSession(transport, stack)
                        val compose = EditableFile.Compose(file)

                        val opened = session.read(compose)
                        expect("read gives back exactly what is on the server", opened.content == original)
                        expect("its hash is the server's own sha256", opened.sha256 == sh("sha256sum $file | cut -d' ' -f1").stdout.trim())

                        val add = Bookmark("https://probe.example.com/", name = "Probe", group = "Test").labelChanges
                        val plan = BookmarkEditor.plan(session, stack, "web", add, false, host)
                        val edit = (plan as? BookmarkPlan.Ready)?.edit
                        expect("the label edit is planned", edit != null)
                        if (edit != null) {
                            expect("comments and other lines are untouched", edit.content.startsWith("# keep me\n") && edit.content.contains("    restart: always"))
                            expect("three labels added", edit.content.lines().count { it.contains("homepage.") } == 3)
                            val check = session.validate(compose, edit.content)
                            expect("the server's compose check accepts it", check.isValid)

                            val saved = session.save(edit, session.confirm(edit))
                            expect("saved (got $saved)", saved is SaveOutcome.Saved)
                            val onServer = sh("cat $file").stdout
                            expect("the file on the server is the new text", onServer == edit.content)
                            expect("the old file is kept as compose.yaml.rackoon.bak", sh("cat $file.rackoon.bak").stdout == original)
                            expect("permissions are carried over (640)", sh("stat -c %a $file").stdout.trim() == "640")
                            if (saved is SaveOutcome.Saved) expect("the returned hash is the new file's", saved.sha256 == sh("sha256sum $file | cut -d' ' -f1").stdout.trim())

                            // The guard: someone else changes the file after it was opened, then the old edit is saved.
                            sh("echo '# external edit' >> $file")
                            val stale = session.save(edit.copy(content = edit.content + "# mine\n"), session.confirm(edit.copy(content = edit.content + "# mine\n")))
                            expect("a change made on the server in between is noticed (got $stale)", stale == SaveOutcome.ChangedOnServer)
                            expect("and the external edit is still there", sh("cat $file").stdout.contains("# external edit"))

                            // Removing the bookmark again.
                            val reread = session.read(compose)
                            val removal = BookmarkEditor.plan(session, stack, "web", Bookmark.removalChanges, true, host)
                            val removeEdit = (removal as? BookmarkPlan.Ready)?.edit
                            expect("the removal is planned", removeEdit != null)
                            if (removeEdit != null) {
                                expect("removal drops the labels block, keeps the rest", !removeEdit.content.contains("homepage.") && !removeEdit.content.contains("labels:") && removeEdit.content.contains("# external edit"))
                                expect("removal saved", session.save(removeEdit, session.confirm(removeEdit)) is SaveOutcome.Saved)
                                expect("no homepage labels left on the server", !sh("cat $file").stdout.contains("homepage."))
                            }
                            expect("the file was read again before the removal", reread.content != null)
                        }
                        val bad = session.validate(compose, "services:\n  web:\n    imagee: nginx\n")
                        expect("a wrong key is rejected by the server's check", !bad.isValid)
                        val badSave = FileEdit(compose, original, sh("sha256sum $file | cut -d' ' -f1").stdout.trim(), "services:\n  web:\n    imagee: nginx\n")
                        val refused = session.save(badSave, session.confirm(badSave))
                        expect("saving an invalid file is refused (got $refused)", refused is SaveOutcome.Invalid)
                    } finally {
                        sh("rm -rf $dir")
                        expect("the throwaway folder is gone", sh("[ ! -e $dir ] && echo gone").stdout.trim() == "gone")
                    }
                }

                "sandbox-up", "sandbox-down" -> {
                    val dir = "/tmp/rackoon-sandbox"
                    val project = "rackoonsandbox"
                    val file = "$dir/compose.yaml"
                    suspend fun sh(cmd: String) = transport.run(cmd, 300_000)
                    if (check == "sandbox-up") {
                        println("  will create $dir/compose.yaml and run: docker compose -p $project -f $file up -d   (nothing else is touched)")
                        val exists = sh("[ -e $dir ] && echo yes || echo no").stdout.trim() == "yes"
                        expect("the sandbox is not already there", !exists)
                        if (!exists) {
                            val compose = "services:\n  web:\n    image: nginxdemos/hello\n    ports:\n      - \"127.0.0.1:18080:80\"\n" +
                                "    labels:\n      - homepage.name=Sandbox\n      - homepage.href=http://127.0.0.1:18080/\n" +
                                "  cache:\n    image: redis:alpine\n"
                            val b64 = java.util.Base64.getEncoder().encodeToString(compose.toByteArray())
                            val up = sh("mkdir -p $dir && echo $b64 | base64 -d > $file && docker compose -p $project -f $file up -d 2>&1")
                            println(up.stdout.trim().lines().joinToString("\n") { "    $it" })
                            expect("the stack started", up.exitCode == 0)
                            val ps = sh("docker ps --filter label=com.docker.compose.project=$project --format '{{.Names}}  {{.Status}}  {{.Ports}}'").stdout
                            println(ps.trim().lines().joinToString("\n") { "    $it" })
                            expect("two containers are running", ps.trim().lines().count { it.isNotBlank() } == 2)
                        }
                    } else {
                        println("  will run: docker compose -p $project -f $file down -v --remove-orphans, then remove exactly $dir")
                        val down = sh("[ -f $file ] && docker compose -p $project -f $file down -v --remove-orphans 2>&1; rm -rf $dir; echo cleaned")
                        println(down.stdout.trim().lines().joinToString("\n") { "    $it" })
                        expect("no sandbox containers are left", sh("docker ps -a --filter label=com.docker.compose.project=$project -q").stdout.isBlank())
                        expect("the sandbox folder is gone", sh("[ ! -e $dir ] && echo gone").stdout.trim() == "gone")
                    }
                }

                else -> { System.err.println("unknown check $check"); exitProcess(2) }
            }
        } finally {
            transport.close()
        }
    }
    if (failures.isEmpty()) println("PASS") else { println("FAILED: ${failures.size}"); exitProcess(1) }
}
