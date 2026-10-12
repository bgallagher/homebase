package com.bgallagher.rackoon.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A fake server for the Add container page: image lookups, listening ports, scratch checks, creates and file reads/saves. */
private class FakeAddServer : SSHTransport {
    var composeText = "services:\n  web:\n    image: nginx\n"
    var envText: String? = null
    var imageFound = true
    var listening = "LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*\n"
    var rejectCheck: String? = null
    var warnWith: String? = null
    var exists = false
    var composeChecks = 0
    val created = mutableListOf<String>()
    var changeUnderneath = false
    private fun sha(t: String) = java.security.MessageDigest.getInstance("SHA-256").digest(t.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun content(c: String): String {
        val b64 = Regex("""echo '([A-Za-z0-9+/=]*)' \| base64 -d""").find(c)?.groupValues?.get(1).orEmpty()
        return if (b64.isEmpty()) "" else String(java.util.Base64.getDecoder().decode(b64))
    }
    override suspend fun run(command: String, timeoutMillis: Long): CommandResult = when {
        command.startsWith("timeout 20 docker manifest inspect") -> CommandResult(if (imageFound) "found\n" else "notfound\n")
        command == "ss -H -tln 2>/dev/null" -> CommandResult(listening)
        command.startsWith("T=\$(mktemp -d)") -> { composeChecks++; rejectCheck?.let { CommandResult("$it\n", exitCode = 1) } ?: CommandResult(warnWith?.plus("\n") ?: "") }
        command.startsWith("D=") && command.contains("##created") -> if (exists) CommandResult("##exists\n", exitCode = 3) else { created += command; CommandResult("##created\n") }
        command.startsWith("F='") && command.contains("echo '##meta'") -> {
            val text = if (command.contains(".env'")) envText else composeText
            if (text == null) CommandResult("##missing\n") else CommandResult("##meta\n1 644 root:root\n##sha256\n${sha(text)}\n##content\n${java.util.Base64.getEncoder().encodeToString(text.toByteArray())}\n")
        }
        command.contains(".rackoon-check.") -> { composeChecks++; rejectCheck?.let { CommandResult("$it\n", exitCode = 1) } ?: CommandResult("") }
        command.contains("echo '##saved'") ->
            if (changeUnderneath) CommandResult("##changed\n", exitCode = 3)
            else { val t = content(command); if (command.contains("/.env")) envText = t else composeText = t; CommandResult("##saved\n${sha(t)}\n") }
        else -> CommandResult("")
    }
    override fun stream(command: String) = kotlinx.coroutines.flow.emptyFlow<String>()
}

@OptIn(ExperimentalCoroutinesApi::class)
class AddContainerDraftTests {
    private fun container(service: String, project: String, ports: List<DockerContainer.PortMapping> = emptyList()) = DockerContainer(
        id = "abcdef0123" + service.take(2), name = "$project-$service-1", image = "x", state = "running", health = "none", status = "Up", ports = ports,
        project = project, service = service, workingDir = "/opt/stacks/$project", configFile = "/opt/stacks/$project/compose.yaml", configFiles = listOf("/opt/stacks/$project/compose.yaml"),
    )

    private val media = container("web", "media", listOf(DockerContainer.PortMapping(8080, 80, "tcp")))
    private fun mediaStack() = DockerStack("media", "/opt/stacks/media", "/opt/stacks/media/compose.yaml", listOf("/opt/stacks/media/compose.yaml"), listOf(media), false)

    private class Setup(val draft: AddContainerDraft, val server: FakeAddServer, val policy: ActionPolicy)

    private fun TestScope.setup(server: FakeAddServer = FakeAddServer(), readOnly: Boolean = false): Setup {
        val policy = ActionPolicy(readOnly)
        val stacks = listOf(mediaStack())
        val draft = AddContainerDraft(server, policy, "hetzner", this, "/opt/stacks", { stacks }, { stacks.flatMap { it.containers } })
        return Setup(draft, server, policy)
    }

    private val kuma = ContainerSpec(name = "uptime-kuma", image = "louislam/uptime-kuma:1", ports = listOf(PortRow("3001", "3001")), volumes = listOf(VolumeRow("./data", "/app/data")), env = listOf(EnvRow("TZ", "Europe/Dublin")))

    @Test fun `a new stack from the form passes all checks and can be created and started`() = runTest {
        val s = setup()
        s.draft.start()
        s.draft.setStackName("kuma")
        s.draft.setSpec(kuma)
        advanceUntilIdle()
        val state = s.draft.state.value
        assertEquals(listOf("YAML syntax", "Image", "Port 3001", "Container name"), s.draft.rows().map { it.title })
        assertTrue(s.draft.rows().all { it.state == EditorCheckRow.State.PASS }, s.draft.rows().toString())
        assertNull(s.draft.deployBlockedReason(state))
        val request = assertNotNull(s.draft.request(start = true)) as DeployRequest.NewStack
        assertEquals("Create kuma and start it?", request.title)
        assertTrue(request.preview.contains("Create folder /opt/stacks/kuma"))
        assertTrue(request.preview.contains(".env"))
        var result: DeployResult? = null
        s.draft.perform(request) { result = it }
        advanceUntilIdle()
        assertEquals(DeployResult(request.stack, isNew = true, start = true), result)
        assertEquals(1, s.server.created.size)
        assertFalse(s.draft.state.value.working)
        s.draft.close()
    }

    @Test fun `problems block the button with a reason`() = runTest {
        val s = setup()
        s.draft.start()
        assertEquals("Enter a stack name", s.draft.deployBlockedReason())
        s.draft.setStackName("media")
        assertEquals("A stack named media already exists", s.draft.deployBlockedReason())
        s.draft.setStackName("kuma")
        assertEquals("Enter a container name", s.draft.deployBlockedReason())
        s.draft.setSpec(kuma.copy(ports = listOf(PortRow("8080", "80"))))
        advanceUntilIdle()
        val rows = s.draft.rows()
        val port = rows.first { it.id == "port8080" }
        assertEquals(EditorCheckRow.State.FAIL, port.state)
        assertEquals("By web in media. Try 8081.", port.detail)
        assertTrue(s.draft.deployBlockedReason()!!.startsWith("Port 8080 is already in use"))
        s.draft.close()
    }

    @Test fun `a missing image blocks and a slow registry only warns`() = runTest {
        val server = FakeAddServer().also { it.imageFound = false }
        val s = setup(server)
        s.draft.start(); s.draft.setStackName("kuma"); s.draft.setSpec(kuma); advanceUntilIdle()
        assertEquals(EditorCheckRow.State.FAIL, s.draft.rows().first { it.id == "image" }.state)
        assertTrue(s.draft.deployBlockedReason()!!.startsWith("Image:"))
        s.draft.close()
    }

    @Test fun `a server that rejects the compose blocks and shows why`() = runTest {
        val server = FakeAddServer().also { it.rejectCheck = "yaml: line 4: mapping values are not allowed here" }
        val s = setup(server)
        s.draft.start(); s.draft.setStackName("kuma"); s.draft.setSpec(kuma); advanceUntilIdle()
        val first = s.draft.rows().first()
        assertEquals(EditorCheckRow.State.FAIL, first.state)
        assertTrue(first.detail.contains("Line 4"))
        assertNotNull(s.draft.deployBlockedReason())
        s.draft.close()
    }

    @Test fun `read-only blocks everything`() = runTest {
        val s = setup(readOnly = true)
        s.draft.start(); s.draft.setStackName("kuma"); s.draft.setSpec(kuma); advanceUntilIdle()
        assertEquals("Read-only mode is on", s.draft.deployBlockedReason())
        assertNull(s.draft.request(start = false))
        s.draft.close()
    }

    @Test fun `pasting a compose file replaces the form and is checked by the server`() = runTest {
        val s = setup()
        s.draft.start(); s.draft.setStackName("hello"); s.draft.setPaste(true)
        s.draft.setPasteCompose("services:\n  hello:\n    image: nginxdemos/hello\n    ports:\n      - \"\${TS_IP}:8081:80\"\n")
        s.draft.setPasteEnv("TS_IP=100.64.0.1\n")
        advanceUntilIdle()
        assertEquals(listOf("YAML syntax", "Pasted file"), s.draft.rows().map { it.title })
        assertNull(s.draft.deployBlockedReason())
        val request = s.draft.request(start = false) as DeployRequest.NewStack
        assertEquals("services:\n  hello:\n    image: nginxdemos/hello\n    ports:\n      - \"\${TS_IP}:8081:80\"\n", request.plan.compose)
        assertEquals("TS_IP=100.64.0.1\n", request.plan.env)
        // A bad .env is caught locally, before any server round trip.
        s.draft.setPasteEnv("BAD LINE\n")
        assertTrue(s.draft.deployBlockedReason()!!.startsWith("Fix .env"))
        s.draft.close()
    }

    @Test fun `unset variables in a pasted file can be added to the env with one tap`() = runTest {
        val server = FakeAddServer().also {
            it.warnWith = "time=\"t\" level=warning msg=\"The \\\"DB_PASSWORD\\\" variable is not set. Defaulting to a blank string.\""
        }
        val s = setup(server)
        s.draft.start(); s.draft.setStackName("x"); s.draft.setPaste(true)
        s.draft.setPasteCompose("services:\n  a:\n    image: x\n    environment:\n      K: \${DB_PASSWORD}\n")
        advanceUntilIdle()
        assertEquals(listOf("DB_PASSWORD"), s.draft.missingVariables())
        s.draft.addMissingVariables(); advanceUntilIdle()
        assertEquals("DB_PASSWORD=\n", s.draft.state.value.pasteEnv)
        assertEquals(emptyList(), s.draft.missingVariables(), "once the .env defines it, it is no longer missing")
        s.draft.close()
    }

    @Test fun `adding to an existing stack inserts the service and merges the env`() = runTest {
        val server = FakeAddServer().also { it.envText = "TZ=UTC\n" }
        val s = setup(server)
        s.draft.start()
        s.draft.setTarget(AddTarget.EXISTING)
        s.draft.chooseExisting("media")
        s.draft.setSpec(kuma)
        advanceUntilIdle()
        val composeNow = s.draft.composeText()
        assertTrue(composeNow.startsWith("services:\n  web:\n    image: nginx\n  uptime-kuma:\n"), composeNow)
        assertEquals("TZ=UTC\n", s.draft.envText(), "TZ is already there: its value is kept")
        assertTrue(s.draft.rows().any { it.id == "envkept" && it.detail.contains("TZ") })
        assertNull(s.draft.deployBlockedReason())
        val request = s.draft.request(start = false) as DeployRequest.ExistingStack
        assertEquals(listOf("compose.yaml"), request.edits.map { it.file.fileName }, "no env edit when nothing new is added")
        var result: DeployResult? = null
        s.draft.perform(request) { result = it }
        advanceUntilIdle()
        assertEquals(false, result?.isNew)
        assertTrue(server.composeText.contains("uptime-kuma:"))
        s.draft.close()
    }

    @Test fun `a new env variable is written first and then the compose`() = runTest {
        val server = FakeAddServer().also { it.envText = "OTHER=1\n" }
        val s = setup(server)
        s.draft.start(); s.draft.setTarget(AddTarget.EXISTING); s.draft.chooseExisting("media"); s.draft.setSpec(kuma); advanceUntilIdle()
        val request = s.draft.request(start = true) as DeployRequest.ExistingStack
        assertEquals(listOf(".env", "compose.yaml"), request.edits.map { it.file.fileName })
        assertTrue(request.preview.contains(".env"))
        s.draft.perform(request) {}
        advanceUntilIdle()
        assertEquals("OTHER=1\nTZ=Europe/Dublin\n", server.envText)
        s.draft.close()
    }

    @Test fun `an inline services block or a duplicate name is refused with the reason`() = runTest {
        val server = FakeAddServer().also { it.composeText = "services: {}\n" }
        val s = setup(server)
        s.draft.start(); s.draft.setTarget(AddTarget.EXISTING); s.draft.chooseExisting("media"); s.draft.setSpec(kuma); advanceUntilIdle()
        assertTrue(s.draft.deployBlockedReason()!!.contains("one line"))
        assertEquals(EditorCheckRow.State.FAIL, s.draft.rows().first { it.id == "insert" }.state)
        server.composeText = "services:\n  uptime-kuma:\n    image: a\n"
        s.draft.chooseExisting("media"); advanceUntilIdle()
        assertTrue(s.draft.deployBlockedReason()!!.contains("already has a service called uptime-kuma"))
        s.draft.close()
    }

    @Test fun `a file changed on the server in between is not overwritten`() = runTest {
        val server = FakeAddServer()
        val s = setup(server)
        s.draft.start(); s.draft.setTarget(AddTarget.EXISTING); s.draft.chooseExisting("media"); s.draft.setSpec(kuma.copy(env = listOf(EnvRow()))); advanceUntilIdle()
        val request = s.draft.request(start = false)!!
        server.changeUnderneath = true
        var done = false
        s.draft.perform(request) { done = true }
        advanceUntilIdle()
        assertFalse(done)
        assertTrue(s.draft.state.value.notice!!.contains("changed on hetzner"))
        assertEquals("services:\n  web:\n    image: nginx\n", server.composeText)
        s.draft.close()
    }

    @Test fun `creating over an existing folder reports it`() = runTest {
        val server = FakeAddServer().also { it.exists = true }
        val s = setup(server)
        s.draft.start(); s.draft.setStackName("kuma"); s.draft.setSpec(kuma); advanceUntilIdle()
        s.draft.perform(s.draft.request(start = false)!!) { error("must not finish") }
        advanceUntilIdle()
        assertTrue(s.draft.state.value.notice!!.contains("already exists"))
        s.draft.close()
    }
}
