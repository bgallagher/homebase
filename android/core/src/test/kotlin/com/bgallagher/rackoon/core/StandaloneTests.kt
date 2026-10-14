package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Mirrors StandaloneTests.swift: a container started with `docker run` is a stack of its own. */
class StandaloneStackTests {
    private fun container(name: String, project: String? = null, image: String = "nginx:1.27", id: String = "abcdef012345") = DockerContainer(
        id = id, name = name, image = image, state = "running", health = "none", status = "Up", ports = emptyList(),
        project = project, service = if (project == null) null else "web",
        workingDir = project?.let { "/srv/$it" }, configFile = project?.let { "/srv/$it/compose.yaml" },
    )

    @Test fun everyStandaloneContainerGetsItsOwnStackWithAUniqueId() {
        val snapshot = DockerSnapshot(listOf(
            container("Portainer", id = "111111111111"),
            container("media-web-1", project = "media", id = "222222222222"),
            container("adguard", id = "333333333333"),
            container("media", id = "444444444444"),   // a standalone container named like a compose project
        ))
        val stacks = snapshot.stacks
        assertEquals(listOf("adguard", "media", "media", "Portainer"), stacks.map { it.name }, "by name ignoring case; compose first on a tie")
        assertEquals(listOf(true, false, true, true), stacks.map { it.isStandalone })
        assertEquals(listOf("standalone/adguard", "media", "standalone/media", "standalone/Portainer"), stacks.map { it.id })
        assertEquals(stacks.size, stacks.map { it.id }.toSet().size, "ids never clash")
        assertTrue(stacks.filter { it.isStandalone }.all { it.containers.size == 1 })
        assertEquals(listOf("Standalone", "Compose Stack", "Standalone", "Standalone"), stacks.map { it.kindLabel })
    }

    @Test fun aContainerKnowsWhichStackItIsShownIn() {
        assertEquals("media", DockerStack.idOf(container("media-web-1", project = "media")))
        assertEquals("standalone/adguard", DockerStack.idOf(container("adguard")))
    }

    @Test fun theOrderDoesNotDependOnDockersListingOrder() {
        val a = container("media", id = "444444444444")
        val b = container("media-web-1", project = "media", id = "222222222222")
        assertEquals(DockerSnapshot(listOf(a, b)).stacks.map { it.id }, DockerSnapshot(listOf(b, a)).stacks.map { it.id })
    }

    @Test fun composeActionsStillRefuseStandaloneStacks() {
        val stack = DockerSnapshot(listOf(container("adguard"))).stacks.first()
        for (action in ComposeAction.entries) assertNull(action.command(stack), action.raw)
        assertNull(StackRemoval().command(stack))
        assertNull(StackFiles.editable(stack))
    }
}

class StandaloneActionTests {
    private fun stack(image: String = "nginx:1.27", id: String = "abcdef012345", standalone: Boolean = true, name: String = "adguard"): DockerStack {
        val c = DockerContainer(id = id, name = name, image = image, state = "running", health = "none", status = "Up", ports = emptyList())
        return DockerStack(name, null, null, emptyList(), listOf(c), standalone)
    }

    @Test fun theCommandsComeFromTheSpecAsActions() {
        // The Kotlin core reads the scripts from spec/commands.json itself, so there is no copy to compare; check the entries exist as actions.
        val commands = Json.parseToJsonElement(Spec.text("commands.json")).jsonObject.getValue("commands").jsonArray.map { it.jsonObject }
        fun spec(id: String) = commands.firstOrNull { it["id"]?.jsonPrimitive?.content == id }
        assertEquals("docker pull {image}", spec(StandaloneAction.PULL_COMMAND_ID)?.get("script")?.jsonPrimitive?.content)
        assertEquals("docker rm -f{volumes} {id}", spec(StandaloneAction.REMOVE_COMMAND_ID)?.get("script")?.jsonPrimitive?.content)
        assertEquals("action", spec(StandaloneAction.PULL_COMMAND_ID)?.get("kind")?.jsonPrimitive?.content)
        assertEquals("action", spec(StandaloneAction.REMOVE_COMMAND_ID)?.get("kind")?.jsonPrimitive?.content)
    }

    @Test fun commandsAreExact() {
        assertEquals("docker pull 'nginx:1.27'", StandaloneAction.PullImage.command(stack()))
        val digest = "a".repeat(64)
        assertEquals("docker pull 'ghcr.io/org/app@sha256:$digest'", StandaloneAction.PullImage.command(stack(image = "ghcr.io/org/app@sha256:$digest")))
        assertEquals("docker rm -f abcdef012345", StandaloneAction.Remove(false).command(stack()))
        assertEquals("docker rm -f -v abcdef012345", StandaloneAction.Remove(true).command(stack()))
        assertEquals("Delete container adguard and its anonymous volumes", StandaloneAction.Remove(true).intent(stack())?.summary)
        assertEquals(Risk.MUTATE, StandaloneAction.PullImage.intent(stack())?.risk)
    }

    @Test fun onlyAStandaloneStackOfOneContainerIsAccepted() {
        assertNull(StandaloneAction.PullImage.command(stack(standalone = false)))
        assertNull(StandaloneAction.Remove(false).command(stack(standalone = false)))
        val one = stack()
        val two = one.copy(containers = one.containers + one.containers)
        assertNull(StandaloneAction.Remove(false).command(two))
    }

    @Test fun unsafeOrUnpullableValuesAreRefused() {
        for (bad in listOf("", "-flag", "nginx; reboot", "nginx \$(id)", "a'b", "nginx\nreboot", "sha256:" + "a".repeat(64), "abcdef012345", "b".repeat(64), "ünïcode")) {
            assertNull(StandaloneAction.PullImage.command(stack(image = bad)), bad)
        }
        for (bad in listOf("abc", "ABCDEF012345", "abcdef012345; rm -rf /", "\$(whoami)abcdef")) {
            assertNull(StandaloneAction.Remove(false).command(stack(id = bad)), bad)
        }
        assertNotNull(StandaloneAction.PullImage.command(stack(image = "registry.local:5000/team/app:v1.2_rc-3")))
    }

    @Test fun streamsUnderTheStackIdAndNeedsAConfirmation() = runTest {
        val t = FakeTransport(listOf(ok(Spec.out("docker", "ubuntu-24.04-compose"))))
        t.streamChunks = listOf("1.27: Pulling from library/nginx\r\n", "\r\n##rackoon-exit:0\r\n")
        val session = DockerSession(t)
        val got = Collector()

        session.performStreaming(StandaloneAction.PullImage, stack(), null, 80, 24) { got.add(it) }
        assertTrue(t.streamedCommands.isEmpty(), "nothing runs without a confirmation")
        assertEquals(listOf<ActionStreamEvent>(ActionStreamEvent.Finished(null)), got.events)

        val confirmation = session.confirm(StandaloneAction.PullImage, stack())
        session.performStreaming(StandaloneAction.PullImage, stack(), confirmation, 80, 24) { got.add(it) }
        assertEquals(listOf(StreamedCommand.wrap("docker pull 'nginx:1.27'", 80, 24)), t.streamedCommands)
        assertEquals(ActionStreamEvent.Finished(0), got.events.last())
        val state = session.state.value
        assertNull(state.actionError)
        assertTrue(state.busy.isEmpty() && state.busyStacks.isEmpty())

        assertFailsWith<PolicyError>("a compose stack is not deleted with docker rm") { session.confirm(StandaloneAction.Remove(false), stack(standalone = false)) }
        assertFailsWith<PolicyError> { DockerSession(t, policy = ActionPolicy(readOnly = true)).confirm(StandaloneAction.Remove(false), stack()) }
    }

    @Test fun standalonePromptsAndBlockedReasons() {
        assertNull(ActionPrompts.standaloneBlockedReason(stack(), readOnly = false, otherActionRunning = false))
        assertEquals("Read-only mode is on", ActionPrompts.standaloneBlockedReason(stack(), readOnly = true, otherActionRunning = false))
        assertEquals("Another stack action is running", ActionPrompts.standaloneBlockedReason(stack(), readOnly = false, otherActionRunning = true))
        assertEquals("This container can't be addressed safely", ActionPrompts.standaloneBlockedReason(stack(id = "nope"), readOnly = false, otherActionRunning = false))
        assertEquals("Pull the latest nginx:1.27?", ActionPrompts.pull(stack())?.title)
        assertNull(ActionPrompts.pull(stack(image = "abcdef012345")), "an untagged image (shown as its id) can't be pulled")
    }
}
