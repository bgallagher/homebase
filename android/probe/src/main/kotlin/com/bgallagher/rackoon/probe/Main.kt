package com.bgallagher.rackoon.probe

import com.bgallagher.rackoon.core.ActionStreamEvent
import com.bgallagher.rackoon.core.ActionPolicy
import com.bgallagher.rackoon.core.EditorChecks
import com.bgallagher.rackoon.core.EnvSyntax
import com.bgallagher.rackoon.core.RemoteFileState
import com.bgallagher.rackoon.core.Bookmark
import com.bgallagher.rackoon.core.ComposeAction
import com.bgallagher.rackoon.core.LogFollower
import com.bgallagher.rackoon.core.DockerParser
import com.bgallagher.rackoon.core.DockerSession
import com.bgallagher.rackoon.core.PolicyError
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
 *   compose-test   REAL pull/update/rebuild/recreate/streamed runs/read-only checks on a throwaway stack under /tmp that it creates and
 *                  removes (project rackoon-probe-test). Never touches your own stacks.
 *   env-test       REAL .env editing on a throwaway stack under /tmp (project rackoon-probe-env): a missing .env, create it, check it with
 *                  the server's --env-file, the not-exists guard when it appears underneath, edit it, and the checklist
 *   logs-check     LogFollower follows TWO real containers merged for a few seconds (read-only), then stops: no `docker logs -f` is left
 *                  running on the server
 *   exec-shell-check  a command on a pty and an interactive shell both work through the real SSH library (what Shell-in-container uses)
 *   sandbox-up     REAL: creates ONE harmless stack, /tmp/rackoon-sandbox (project rackoonsandbox: a hello-world web page on
 *                  127.0.0.1:18080 and redis), and starts it, so the phone's Docker actions can be tried on it
 *   sandbox-down   REAL: stops and removes exactly that stack and its folder. Neither touches anything else.
 * Every other check only reads, or works on nothing but its own temporary process; none changes the server.
 */
fun main(args: Array<String>) {
    if (args.size < 2) {
        System.err.println("usage: probe <host> <overview|hostkey|stream-check|stream-marker|shell-check|exec-shell-check|logs-check|env-test|compose-test|bookmark-test|sandbox-up|sandbox-down> [user]")
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

                "env-test" -> {
                    val project = "rackoon-probe-env"
                    val dir = "/tmp/rackoon-probe-env-stack"
                    val file = "$dir/compose.yaml"
                    suspend fun sh(cmd: String) = transport.run(cmd, 120_000)
                    try {
                        val compose = "services:\n  web:\n    image: busybox:1.36\n    command: sleep 3600\n    environment:\n      - GREETING=${'$'}{GREETING:?set GREETING in .env}\n"
                        val b64 = java.util.Base64.getEncoder().encodeToString(compose.toByteArray())
                        expect("throwaway folder created", sh("rm -rf $dir; mkdir -p $dir && echo $b64 | base64 -d > $file").exitCode == 0)
                        val container = com.bgallagher.rackoon.core.DockerContainer(
                            id = "abcdef012345", name = "$project-web-1", image = "busybox:1.36", state = "running", health = "none", status = "Up", ports = emptyList(),
                            project = project, service = "web", workingDir = dir, configFile = file, configFiles = listOf(file),
                        )
                        val stack = DockerStack(project, dir, file, listOf(file), listOf(container), false)
                        val session = com.bgallagher.rackoon.core.StackFileSession(transport, stack, ActionPolicy())
                        val env = com.bgallagher.rackoon.core.EditableFile.Env("$dir/.env")
                        val comp = com.bgallagher.rackoon.core.EditableFile.Compose(file)

                        expect(".env is reported missing", session.read(env) == RemoteFileState.Missing)
                        // The compose file needs GREETING, so it fails without a .env: the checklist must say so, not pass.
                        val without = session.validate(comp, compose)
                        expect("without a .env the compose check fails (${without.errors.firstOrNull()?.message?.take(70)})", !without.isValid)
                        val rows = EditorChecks.rows(false, "hetzner", emptyList(), null, without, compose, compose)
                        expect("and the checklist says which step failed", rows.any { it.state == com.bgallagher.rackoon.core.EditorCheckRow.State.FAIL })

                        val good = "GREETING=hello\n"
                        expect("local env syntax accepts it", EnvSyntax.check(good).isEmpty())
                        expect("the server's --env-file check accepts the new .env", session.validate(env, good).isValid)
                        val bad = "GREETING hello\n"
                        expect("local env syntax rejects 'GREETING hello' on line 1", EnvSyntax.check(bad).firstOrNull()?.line == 1)

                        val create = com.bgallagher.rackoon.core.FileEdit(env, null, null, good)
                        val saved = session.save(create, session.confirm(create))
                        expect("a new .env is created (got $saved)", saved is com.bgallagher.rackoon.core.SaveOutcome.Saved)
                        expect("it is on the server with that content", sh("cat $dir/.env").stdout == good)
                        expect("a new file is private (mode 600)", sh("stat -c %a $dir/.env").stdout.trim() == "600")
                        expect("the stack now resolves with it", session.validate(comp, compose).isValid)

                        // The not-exists guard: the file is created by someone else after the editor opened it as missing.
                        sh("rm -f $dir/.env && echo 'OTHER=1' > $dir/.env")
                        val raced = session.save(create, session.confirm(create))
                        expect("a .env that appeared underneath is not overwritten (got $raced)", raced == com.bgallagher.rackoon.core.SaveOutcome.ChangedOnServer)
                        expect("and what is on the server is untouched", sh("cat $dir/.env").stdout == "OTHER=1\n")

                        // Edit an existing .env with the sha guard, and keep the backup.
                        val opened = session.read(env) as RemoteFileState.File
                        val edit = com.bgallagher.rackoon.core.FileEdit(env, opened.file.content, opened.file.sha256, "GREETING=bye\nOTHER=2\n")
                        val second = session.save(edit, session.confirm(edit))
                        expect("an existing .env is edited (got $second)", second is com.bgallagher.rackoon.core.SaveOutcome.Saved)
                        expect("its backup keeps the old content", sh("cat $dir/.env.rackoon.bak").stdout == "OTHER=1\n")
                        expect("permissions of the existing file are carried over", sh("stat -c %a $dir/.env").stdout.trim() == sh("stat -c %a $dir/.env.rackoon.bak").stdout.trim())
                    } finally {
                        sh("rm -rf $dir")
                        expect("the throwaway folder is gone", sh("[ ! -e $dir ] && echo gone").stdout.trim() == "gone")
                    }
                }

                "logs-check" -> {
                    val snapshot = DockerParser.parse(transport.run(com.bgallagher.rackoon.core.DockerSession.command, 30_000).stdout)
                    val chosen = snapshot.containers.filter { it.isRunning }.take(2)
                    expect("two running containers to follow (found ${chosen.size})", chosen.size == 2)
                    if (chosen.size == 2) {
                        val follower = LogFollower(transport)
                        follower.follow(this, chosen)
                        delay(6_000)
                        val st = follower.state.value
                        println("   received ${st.received} lines from ${st.entries.map { it.source }.distinct()}")
                        expect("following is live", st.live)
                        expect("no error", st.error == null)
                        expect("lines arrived (the last 100 of each are replayed)", st.received > 0)
                        val during = transport.run("pgrep -af 'docker logs -f --tail 100' | grep -v pgrep | wc -l", 10_000).stdout.trim().toInt()
                        expect("one follower per container is running on the server (found $during)", during >= 2)
                        follower.stop()
                        delay(3_000)
                        val left = transport.run("pgrep -af 'docker logs -f --tail 100' | grep -v pgrep | wc -l", 10_000).stdout.trim()
                        expect("no follower left on the server after stop (found $left)", left == "0")
                    }
                }

                "exec-shell-check" -> {
                    // A command on a pty (like `docker exec -it`): it sees the requested size, and its own exit status comes back.
                    val one = transport.openShell(90, 20, "stty size; echo DONE\$((3+4))")
                    val seenOne = StringBuilder()
                    val readerOne = async { one.output.collect { seenOne.append(String(it, Charsets.UTF_8)) } }
                    val endOne = withTimeout(10_000) { one.awaitEnd() }
                    readerOne.await()
                    expect("the command's output shows the pty size 20 x 90 (saw ${seenOne.toString().trim().replace("\r", "").replace("\n", " | ")})", seenOne.contains("20 90"))
                    expect("the command ran (DONE7)", seenOne.contains("DONE7"))
                    expect("ends with the command's own status 0 (got $endOne)", endOne == SessionEnd.RemoteExit(0))

                    // An interactive program on a pty: input reaches it, output comes back, and its exit status is reported.
                    val two = transport.openShell(80, 24, "sh")
                    val seenTwo = StringBuilder()
                    val readerTwo = async { two.output.collect { seenTwo.append(String(it, Charsets.UTF_8)) } }
                    delay(800)
                    two.write("echo HI\$((2+3)); exit 3\n".toByteArray())
                    val endTwo = withTimeout(10_000) { two.awaitEnd() }
                    readerTwo.await()
                    expect("typed input reaches the program (HI5)", seenTwo.contains("HI5"))
                    expect("its exit status 3 comes back (got $endTwo)", endTwo == SessionEnd.RemoteExit(3))
                }

                "compose-test" -> {
                    val project = "rackoon-probe-test"
                    val dir = "/tmp/rackoon-probe-stack"
                    val file = "$dir/compose.yaml"
                    suspend fun sh(script: String, timeout: Long = 300_000) = try { transport.run(script, timeout) } catch (e: Exception) { com.bgallagher.rackoon.core.CommandResult("", e.message ?: "ssh failed", 255) }
                    suspend fun teardown() { sh("cd $dir 2>/dev/null && docker compose -p $project -f $file down -v --remove-orphans --rmi local 2>&1; cd /; rm -rf $dir") }
                    teardown()
                    val setup = sh(
                        "mkdir -p $dir/b && cd $dir && printf 'FROM busybox:1.36\\nRUN echo built > /built.txt\\nCMD sleep 3600\\n' > b/Dockerfile && " +
                            "printf 'services:\\n  web:\\n    image: busybox:1.36\\n    command: sleep 3600\\n  built:\\n    build: ./b\\n' > compose.yaml && " +
                            "docker compose -p $project -f $file up -d --build 2>&1", 600_000,
                    )
                    expect("setup stack up (exit ${setup.exitCode}) ${if (setup.exitCode == 0) "" else setup.stdout.takeLast(300)}", setup.exitCode == 0)
                    if (setup.exitCode != 0) { teardown(); return@runBlocking }

                    val policy = ActionPolicy()
                    val session = DockerSession(transport, policy = policy)
                    suspend fun theStack(): com.bgallagher.rackoon.core.DockerStack? { session.refresh(); return session.state.value.snapshot?.stacks?.firstOrNull { it.name == project } }
                    fun ids(st: com.bgallagher.rackoon.core.DockerStack?) = st?.containers?.map { it.id }?.toSet() ?: emptySet()

                    var stack = theStack()
                    expect("probe stack is listed with 2 containers", stack?.containers?.size == 2)
                    expect("config file label parsed: ${stack?.configFiles}", stack?.configFiles == listOf(file))
                    var current = stack ?: run { teardown(); return@runBlocking }
                    val original = ids(current)

                    suspend fun run(action: ComposeAction): String? {
                        val t0 = System.nanoTime()
                        session.perform(action, current, runCatching { session.confirm(action, current) }.getOrNull())
                        val st = session.state.value
                        println("   ${action.raw} took ${"%.1f".format((System.nanoTime() - t0) / 1e9)}s")
                        expect("${action.raw}: busy cleared afterwards", st.busyStacks.isEmpty() && st.busy.isEmpty())
                        return st.actionError
                    }

                    // Live output: a real compose run over a pty, with the exit code coming back in-band.
                    class Sink { val text = StringBuilder(); var code: Int? = null; var finished = false
                        fun add(e: ActionStreamEvent) { when (e) { is ActionStreamEvent.Output -> text.append(e.text); is ActionStreamEvent.Finished -> { finished = true; code = e.exitCode } } } }
                    for (action in listOf(ComposeAction.RESTART, ComposeAction.UP)) {
                        val sink = Sink()
                        val t0 = System.nanoTime()
                        session.performStreaming(action, current, null, runCatching { session.confirm(action, current) }.getOrNull(), 100, 24) { sink.add(it) }
                        val out = sink.text.toString()
                        println("   streamed ${action.raw} in ${"%.1f".format((System.nanoTime() - t0) / 1e9)}s, ${out.length} chars")
                        expect("streamed ${action.raw} finishes with exit 0: ${sink.code}", sink.finished && sink.code == 0)
                        expect("streamed ${action.raw} shows compose's own progress text", out.contains("Container") || out.contains("web"))
                        expect("the exit marker is never shown", !out.contains("##rackoon-exit"))
                        expect("output arrives with its terminal escapes, not stripped", out.contains("\u001B["))
                        expect("no multi-byte character was cut in two (no U+FFFD)", !out.contains("\uFFFD"))
                        val after = session.state.value
                        expect("${action.raw}: busy cleared, no error", after.busyStacks.isEmpty() && after.actionError == null)
                        theStack()?.let { current = it }
                    }
                    // One container's own restart streams too.
                    current.containers.firstOrNull()?.let { container ->
                        val sink = Sink()
                        session.performStreaming(com.bgallagher.rackoon.core.DockerAction.RESTART, container.id, runCatching { session.confirm(com.bgallagher.rackoon.core.DockerAction.RESTART, container.id) }.getOrNull(), 100, 24) { sink.add(it) }
                        expect("streamed container restart finishes with exit 0: ${sink.code}", sink.finished && sink.code == 0)
                        expect("its output names the container", sink.text.contains(container.id.take(12)) || sink.text.contains(container.name))
                        expect("no marker leaks into a container run either", !sink.text.contains("##rackoon-exit"))
                        theStack()?.let { current = it }
                    }
                    // A failing command reports its real exit code.
                    run {
                        val sink = Sink()
                        val broken = current.copy(configFile = "$dir/does-not-exist.yaml", configFiles = listOf("$dir/does-not-exist.yaml"))
                        session.performStreaming(ComposeAction.UP, broken, null, runCatching { session.confirm(ComposeAction.UP, broken) }.getOrNull(), 100, 24) { sink.add(it) }
                        expect("a failing run reports a non-zero exit code: ${sink.code}", (sink.code ?: 0) != 0)
                        expect("and an error that points at the output", (session.state.value.actionError ?: "").contains("failed (exit"))
                    }

                    expect("pull succeeds", run(ComposeAction.PULL) == null)
                    stack = theStack(); current = stack ?: current
                    expect("pull leaves containers untouched", ids(stack) == original)

                    expect("update (up -d) succeeds", run(ComposeAction.UP) == null)
                    stack = theStack(); current = stack ?: current
                    expect("update with nothing changed keeps the same containers", ids(stack) == original)

                    expect("rebuild succeeds", run(ComposeAction.REBUILD) == null)
                    stack = theStack(); current = stack ?: current
                    expect("rebuild leaves 2 running containers", stack?.containers?.size == 2 && stack.containers.all { it.isRunning })

                    val beforeRecreate = ids(stack)
                    expect("recreate succeeds", run(ComposeAction.RECREATE) == null)
                    stack = theStack(); current = stack ?: current
                    expect("recreate gives every container a new id", ids(stack).intersect(beforeRecreate).isEmpty() && ids(stack).size == 2)
                    expect("recreated containers are running", stack?.containers?.all { it.isRunning } == true)

                    policy.isReadOnly = true
                    val blocked = run(ComposeAction.RECREATE)
                    expect("read-only mode refuses a real stack action: $blocked", blocked == PolicyError.ReadOnly.message)
                    policy.isReadOnly = false
                    expect("nothing changed while read-only", ids(theStack()) == ids(stack))

                    teardown()
                    val leftover = sh("docker ps -a --filter label=com.docker.compose.project=$project -q | wc -l; ls $dir 2>&1 | head -1")
                    expect("teardown removed the containers and directory (${leftover.stdout.replace("\n", " | ")})", leftover.stdout.startsWith("0"))
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
