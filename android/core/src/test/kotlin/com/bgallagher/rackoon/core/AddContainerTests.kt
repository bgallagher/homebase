package com.bgallagher.rackoon.core

import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ContainerSpecTests {
    private fun kuma() = ContainerSpec(
        name = "uptime-kuma", image = "louislam/uptime-kuma:1", ports = listOf(PortRow("3001", "3001"), PortRow()),
        volumes = listOf(VolumeRow("./data", "/app/data")), env = listOf(EnvRow("TZ", "Europe/Dublin")),
    )

    @Test fun `generates the compose from the design`() {
        assertEquals(
            "services:\n  uptime-kuma:\n    image: louislam/uptime-kuma:1\n    restart: unless-stopped\n    ports:\n      - \"3001:3001\"\n" +
                "    volumes:\n      - ./data:/app/data\n    environment:\n      TZ: \${TZ}\n",
            kuma().composeText,
        )
        assertEquals("TZ=Europe/Dublin\n", kuma().envText)
        assertNull(kuma().blockingProblem)
    }

    @Test fun `blank rows and empty sections are left out`() {
        val s = ContainerSpec(name = "web", image = "nginx:alpine", restart = RestartPolicy.NO)
        assertEquals("services:\n  web:\n    image: nginx:alpine\n    restart: \"no\"\n", s.composeText)
        assertEquals("", s.envText)
    }

    @Test fun `problems are reported per field`() {
        var s = kuma().copy(name = "Bad Name!"); assertNotNull(s.nameProblem); assertNotNull(s.blockingProblem)
        s = kuma().copy(image = "nginx; reboot"); assertNotNull(s.imageProblem)
        s = kuma().copy(ports = listOf(PortRow("99999", "80"))); assertNotNull(s.blockingProblem)
        s = kuma().copy(ports = listOf(PortRow("80", ""))); assertNotNull(s.blockingProblem)
        s = kuma().copy(volumes = listOf(VolumeRow("data", "/x"))); assertNotNull(s.blockingProblem)
        s = kuma().copy(volumes = listOf(VolumeRow("./d", "rel"))); assertNotNull(s.blockingProblem)
        s = kuma().copy(env = listOf(EnvRow("1X", "a"))); assertNotNull(s.blockingProblem)
        s = kuma().copy(env = listOf(EnvRow("A", "1"), EnvRow("A", "2"))); assertNotNull(s.blockingProblem)
        assertEquals("Enter a container name", ContainerSpec().blockingProblem)
    }

    @Test fun `env lines are quoted safely and pass the syntax check`() {
        val s = ContainerSpec(name = "a", image = "a", env = listOf(EnvRow("PLAIN", "abc"), EnvRow("SPACE", "a b"), EnvRow("DOLLAR", "p\$ss#1"), EnvRow("QUOTE", "it's"), EnvRow("EMPTY", "")))
        assertEquals("PLAIN=abc\nSPACE='a b'\nDOLLAR='p\$ss#1'\nQUOTE=\"it's\"\nEMPTY=\n", s.envText)
        assertTrue(EnvSyntax.check(s.envText).isEmpty())
    }

    @Test fun `env merge keeps what is there`() {
        val merged = EnvMerge.merge("# comment\nTZ=UTC\nexport KEEP=1", listOf(EnvRow("TZ", "Europe/Dublin"), EnvRow("NEW", "x")))
        assertEquals("# comment\nTZ=UTC\nexport KEEP=1\nNEW=x\n", merged.text)
        assertEquals(listOf("TZ"), merged.kept)
        assertEquals("A=1\n", EnvMerge.merge("A=1\n", listOf(EnvRow("A", "2"))).text)
        assertEquals("A=2\n", EnvMerge.merge("", listOf(EnvRow("A", "2"))).text)
    }

    @Test fun `bind address validation`() {
        assertNull(ContainerSpec.portProblem(PortRow("127.0.0.1:8080", "80")))
        assertNull(ContainerSpec.portProblem(PortRow("\${TS_IP}:8080", "80")))
        assertNotNull(ContainerSpec.portProblem(PortRow("evil;x:8080", "80")))
        assertNotNull(ContainerSpec.portProblem(PortRow("1.2.3:8080", "80")))
        assertEquals(8080, PortRow("\${TS_IP}:8080", "80").hostPort)
        assertEquals("\${TS_IP}", PortRow("\${TS_IP}:8080", "80").bindAddress)
    }

    // MARK: adding to an existing compose file

    @Test fun `adds after the last service and leaves the rest alone`() {
        val file = "# my stack\nservices:\n  nginx:\n    image: nginx:alpine\n    ports:\n      - \"8085:80\"\n\nvolumes:\n  data: {}\n"
        val result = ComposeInsert.adding(kuma(), file)
        assertEquals(
            "# my stack\nservices:\n  nginx:\n    image: nginx:alpine\n    ports:\n      - \"8085:80\"\n  uptime-kuma:\n    image: louislam/uptime-kuma:1\n" +
                "    restart: unless-stopped\n    ports:\n      - \"3001:3001\"\n    volumes:\n      - ./data:/app/data\n    environment:\n      TZ: \${TZ}\n\nvolumes:\n  data: {}\n",
            result,
        )
        assertEquals(listOf("nginx", "uptime-kuma"), ComposeInsert.services(result))
    }

    @Test fun `follows the files indentation`() {
        assertEquals(
            "services:\n    web:\n        image: nginx\n    db:\n        image: postgres:16\n        restart: unless-stopped\n",
            ComposeInsert.adding(ContainerSpec(name = "db", image = "postgres:16"), "services:\n    web:\n        image: nginx\n"),
        )
    }

    @Test fun `refuses duplicates and inline services and adds a missing services key`() {
        assertEquals(ComposeInsertError.ServiceExists("web"), assertFailsWith<ComposeInsertError> { ComposeInsert.adding(ContainerSpec(name = "web", image = "x"), "services:\n  web:\n    image: a\n") })
        assertEquals(ComposeInsertError.InlineServices, assertFailsWith<ComposeInsertError> { ComposeInsert.adding(ContainerSpec(name = "web", image = "x"), "services: {}\n") })
        assertEquals(
            "volumes:\n  d: {}\n\nservices:\n  web:\n    image: x\n    restart: unless-stopped\n",
            ComposeInsert.adding(ContainerSpec(name = "web", image = "x"), "volumes:\n  d: {}\n"),
        )
        // An empty `services:` takes the first service.
        assertEquals("services:\n  web:\n    image: x\n    restart: unless-stopped\n", ComposeInsert.adding(ContainerSpec(name = "web", image = "x"), "services:\n"))
    }

    // MARK: checks

    @Test fun `listening ports fixture`() {
        val expected = Spec.parse("fixtures/listening_ports/basic.expected.json").toString()
        val ports = ContainerChecks.parseListeningPorts(Spec.text("fixtures/listening_ports/basic.out.txt"))
        assertEquals(setOf(22, 53, 80, 3001), ports)
        assertTrue(expected.contains("3001"))
    }

    @Test fun `image command is validated and quoted`() {
        assertEquals(
            "timeout 20 docker manifest inspect 'nginx:alpine' >/dev/null 2>&1; case \$? in 0) echo found;; 124) echo timeout;; *) echo notfound;; esac",
            ContainerChecks.imageCommand("nginx:alpine"),
        )
        for (bad in listOf("", "nginx; reboot", "a b", "\$(id)", "-rm")) assertNull(ContainerChecks.imageCommand(bad), bad)
        assertEquals(ImageStatus.FOUND, ContainerChecks.parseImageStatus("found\n"))
        assertEquals(ImageStatus.TIMED_OUT, ContainerChecks.parseImageStatus("timeout\n"))
        assertEquals(ImageStatus.NOT_FOUND, ContainerChecks.parseImageStatus("notfound\n"))
        assertEquals("Docker Hub", ContainerChecks.registryName("louislam/uptime-kuma:1"))
        assertEquals("ghcr.io", ContainerChecks.registryName("ghcr.io/x/y:1"))
        assertEquals("localhost:5000", ContainerChecks.registryName("localhost:5000/y"))
    }

    @Test fun `port rows name the owner and suggest a free port`() {
        val owner = DockerContainer(
            id = "abcdef012345", name = "boycott-nginx-1", image = "nginx", state = "running", health = "none", status = "Up",
            ports = listOf(DockerContainer.PortMapping(8085, 80, "tcp")), project = "boycottcadbury", service = "nginx",
        )
        val s = kuma().copy(ports = listOf(PortRow("8085", "80"), PortRow("3001", "3001")))
        val rows = ContainerChecks.portRows(s, setOf(22, 8085), listOf(owner), "hetzner")
        assertEquals(listOf(EditorCheckRow.State.FAIL, EditorCheckRow.State.PASS), rows.map { it.state })
        assertEquals("Port 8085 is already in use", rows[0].title)
        assertEquals("By nginx in boycottcadbury. Try 8086.", rows[0].detail)
        assertEquals("Free on hetzner", rows[1].detail)
        assertEquals(listOf(EditorCheckRow.State.RUNNING, EditorCheckRow.State.RUNNING), ContainerChecks.portRows(s, null, emptyList(), "h").map { it.state })
        val twice = s.copy(ports = listOf(PortRow("80", "80"), PortRow("80", "81")))
        assertEquals(listOf(EditorCheckRow.State.FAIL), ContainerChecks.portRows(twice, emptySet(), emptyList(), "h").map { it.state })
    }

    @Test fun `name row`() {
        val existing = DockerContainer(id = "abcdef012345", name = "media-uptime-kuma-1", image = "x", state = "running", health = "none", status = "Up", ports = emptyList(), project = "media", service = "uptime-kuma")
        assertEquals(EditorCheckRow.State.FAIL, ContainerChecks.nameRow(kuma(), "media", listOf(existing)).state)
        assertEquals(EditorCheckRow.State.PASS, ContainerChecks.nameRow(kuma(), "other", listOf(existing)).state)
        assertEquals(EditorCheckRow.State.SKIPPED, ContainerChecks.nameRow(ContainerSpec(), null, emptyList()).state)
    }

    @Test fun `compose row collapses when all pass`() {
        val pass = (0 until 3).map { EditorCheckRow("$it", EditorCheckRow.State.PASS, "t", "") }
        assertEquals(listOf("YAML syntax"), ContainerChecks.composeRow(pass, "h").map { it.title })
        val failing = pass + EditorCheckRow("f", EditorCheckRow.State.FAIL, "docker compose config", "bad")
        assertEquals(listOf("docker compose config"), ContainerChecks.composeRow(failing, "h").map { it.title })
    }
}

class NewStackTests {
    private val cleanup = mutableListOf<File>()

    @AfterTest fun tidy() { cleanup.forEach { it.deleteRecursively() }; cleanup.clear() }

    private fun plan(name: String = "media", parent: String = "/opt/stacks", env: String = "") = NewStackPlan(name = name, parentDirectory = parent, env = env)

    @Test fun `plan paths and validation`() {
        assertEquals("/opt/stacks/media", plan().directory)
        assertEquals("/opt/stacks/media", plan(parent = "/opt/stacks/").directory)
        assertEquals("/media", plan(parent = "/").directory)
        assertEquals("/opt/stacks/media/compose.yaml", plan().composePath)
        assertEquals("/opt/stacks/media", plan().stack?.workingDir)
        assertNotNull(ComposeAction.UP.command(plan().stack!!))
        for (bad in listOf("", "Media", "-x", "a b", "a/b", "a;reboot", "../x")) assertNotNull(plan(name = bad).nameProblem, bad)
        for (bad in listOf("", "relative", "stacks", "/opt/../etc")) {
            assertNotNull(plan(parent = bad).folderProblem, bad)
            assertNull(plan(parent = bad).directory, bad)
        }
        assertNull(NewStackCommands.create(plan(name = "x; reboot")))
        assertNull(NewStackCommands.check(plan(name = "Bad")))
    }

    @Test fun `default parent is learned from the server`() {
        fun stack(name: String, dir: String?, standalone: Boolean = false) = DockerStack(name, dir, null, emptyList(), emptyList(), standalone)
        val stacks = listOf(stack("a", "/opt/stacks/a"), stack("b", "/opt/stacks/b"), stack("c", "/srv/c"), stack("d", null), stack("e", "/mnt/x/e", standalone = true))
        assertEquals("/opt/stacks", NewStackDefaults.parentDirectory(stacks, "root"))
        // A tie goes to the shorter path, so the answer is stable.
        assertEquals("/opt", NewStackDefaults.parentDirectory(listOf(stack("a", "/srv/long/a"), stack("b", "/opt/b")), null))
        assertEquals("/opt/stacks", NewStackDefaults.parentDirectory(emptyList(), "root"))
        assertEquals("/opt/stacks", NewStackDefaults.parentDirectory(emptyList(), null))
        assertEquals("/home/brian/stacks", NewStackDefaults.parentDirectory(emptyList(), "brian"))
    }

    @Test fun `intent has a readable preview and is a mutation`() {
        val intent = NewStackSession(FakeTransport()).intent(plan(env = "A=1\n"))!!
        assertEquals(Risk.MUTATE, intent.risk)
        assertTrue(intent.preview!!.contains("Create folder /opt/stacks/media"))
        assertTrue(intent.preview!!.contains(".env"))
        assertTrue(intent.preview!!.contains("nginx:alpine"))
    }

    @Test fun `create needs confirmation and honours read-only`() = runBlocking {
        val policy = ActionPolicy()
        val transport = FakeTransport()
        val session = NewStackSession(transport, policy)
        assertFailsWith<PolicyError.NotConfirmed> { session.create(plan(), null) }
        assertTrue(transport.commands.isEmpty())
        policy.isReadOnly = true
        assertFailsWith<PolicyError.ReadOnly> { session.confirm(plan()) }
        Unit
    }

    @Test fun `session maps the outcomes`() = runBlocking {
        suspend fun outcome(r: Result<CommandResult>): NewStackOutcome {
            val s = NewStackSession(FakeTransport(listOf(r)))
            return s.create(plan(), s.confirm(plan()))
        }
        assertEquals(NewStackOutcome.Created, outcome(ok("##created\n")))
        assertEquals(NewStackOutcome.Exists, outcome(ok("##exists\n", exitCode = 3)))
        assertEquals(
            NewStackOutcome.Invalid(listOf(ComposeIssue(ComposeIssue.Severity.ERROR, 3, "bad"))),
            outcome(ok("##invalid\nyaml: line 3: bad\n", exitCode = 4)),
        )
        assertFailsWith<StackFileError.CannotWrite> { outcome(ok("##cannot-write\n", exitCode = 7)) }
        assertFailsWith<StackFileError.Malformed> { outcome(ok("", exitCode = 0)) }
        val checked = NewStackSession(FakeTransport(listOf(ok("failed to parse /tmp/tmp.AbC/compose.yaml: bad\n", exitCode = 1)))).check(plan())
        assertFalse(checked.isValid)
        assertEquals("failed to parse compose.yaml: bad", checked.errors.first().message)
        Unit
    }

    @Test fun `scratch paths are simplified in issues`() {
        val issue = ComposeIssue(ComposeIssue.Severity.ERROR, 3, "yaml: /tmp/tmp.AbC123/compose.yaml: bad; see /opt/stacks/x/.env")
        assertEquals("yaml: compose.yaml: bad; see .env", issue.simplifyingScratchPaths().message)
    }

    // MARK: the real scripts under /bin/sh, with a stub `docker`

    private class Ran(val code: Int, val out: String)

    private fun runCreate(plan: NewStackPlan, dockerExit: Int, root: File): Ran {
        val bin = File(root, "bin").also { it.mkdirs() }
        File(bin, "docker").apply { writeText("#!/bin/sh\n[ \"$dockerExit\" = 0 ] || echo 'yaml: line 3: bad' >&2\nexit $dockerExit\n"); setExecutable(true) }
        val p = ProcessBuilder("/bin/sh", "-c", assertNotNull(NewStackCommands.create(plan))).redirectErrorStream(true).also { it.environment()["PATH"] = "${bin.path}:/usr/bin:/bin" }.start()
        val out = p.inputStream.bufferedReader().readText()
        assertTrue(p.waitFor(60, TimeUnit.SECONDS))
        return Ran(p.exitValue(), out)
    }

    private fun temp() = Files.createTempDirectory("rk-new-").toRealPath().toFile().also { cleanup += it }

    @Test fun `create writes files and refuses an existing folder`() {
        val root = temp()
        val p = plan(parent = File(root, "stacks").path, env = "TOKEN=abc\n")
        val first = runCreate(p, 0, root)
        assertEquals(0, first.code, first.out)
        assertTrue(first.out.contains("##created"))
        val dir = File(assertNotNull(p.directory))
        assertEquals(p.compose, File(dir, "compose.yaml").readText())
        assertEquals("TOKEN=abc\n", File(dir, ".env").readText())
        assertEquals(setOf(java.nio.file.attribute.PosixFilePermission.OWNER_READ, java.nio.file.attribute.PosixFilePermission.OWNER_WRITE), Files.getPosixFilePermissions(File(dir, ".env").toPath()))
        // Same name again: refused, and the first stack's files are untouched.
        val second = runCreate(NewStackPlan(name = p.name, parentDirectory = p.parentDirectory, compose = "services: {}\n"), 0, root)
        assertEquals(3, second.code)
        assertTrue(second.out.contains("##exists"))
        assertEquals(p.compose, File(dir, "compose.yaml").readText())
    }

    @Test fun `a failed check leaves nothing behind`() {
        val root = temp()
        val p = plan(parent = File(root, "stacks").path, env = "A=1\n")
        val result = runCreate(p, 1, root)
        assertEquals(4, result.code)
        assertTrue(result.out.contains("##invalid"))
        assertFalse(File(assertNotNull(p.directory)).exists())
    }
}
