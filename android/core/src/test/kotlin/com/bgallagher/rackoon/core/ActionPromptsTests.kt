package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ActionPromptsTests {
    private fun container(service: String?, project: String? = "media", workingDir: String? = "/srv/media") = DockerContainer(
        id = "abcdef012345", name = "media-${service ?: "x"}-1", image = "img", state = "running", health = "none", status = "Up", ports = emptyList(),
        project = project, service = service, workingDir = workingDir, configFile = workingDir?.let { "$it/compose.yaml" }, configFiles = listOfNotNull(workingDir?.let { "$it/compose.yaml" }),
    )

    private fun stack(vararg cs: DockerContainer, standalone: Boolean = false) =
        DockerStack("media", cs.firstOrNull()?.workingDir, cs.firstOrNull()?.configFile, cs.firstOrNull()?.configFiles ?: emptyList(), cs.toList(), standalone)

    @Test fun `unavailable reasons come in the Mac's order`() {
        val ok = stack(container("web"))
        assertNull(ActionPrompts.blockedReason(ok, readOnly = false, otherActionRunning = false))
        assertEquals("Read-only mode is on", ActionPrompts.blockedReason(ok, readOnly = true, otherActionRunning = true))
        assertEquals("Another stack action is running", ActionPrompts.blockedReason(ok, readOnly = false, otherActionRunning = true))
        assertEquals("These containers were not started with Docker Compose", ActionPrompts.blockedReason(stack(container("x", project = null, workingDir = null), standalone = true), false, false))
        assertEquals("No single compose file was found for this stack", ActionPrompts.blockedReason(stack(container("web", workingDir = null)), false, false))
    }

    @Test fun `start has no prompt and stop is the destructive one`() {
        val c = container("web")
        assertNull(ActionPrompts.container(DockerAction.START, c))
        assertTrue(ActionPrompts.container(DockerAction.STOP, c)!!.destructive)
        assertFalse(ActionPrompts.container(DockerAction.RESTART, c)!!.destructive)
        assertEquals("Restart media-web-1?", ActionPrompts.container(DockerAction.RESTART, c)!!.title)
    }

    @Test fun `stack prompts name the stack and count its containers`() {
        val s = stack(container("web"), container("db"))
        assertEquals("Restart all 2 containers in media?", ActionPrompts.stack(ComposeAction.RESTART, s).title)
        assertEquals("Recreate all 1 container in media?", ActionPrompts.stack(ComposeAction.RECREATE, stack(container("web"))).title)
        assertTrue(ActionPrompts.stack(ComposeAction.RECREATE, s).destructive)
        assertFalse(ActionPrompts.stack(ComposeAction.UP, s).destructive)
        assertEquals("Updating media…", ActionPrompts.stack(ComposeAction.UP, s).working)
        for (a in ComposeAction.entries) assertTrue(ActionPrompts.stack(a, s).message.isNotEmpty())
    }

    @Test fun `rebuild applies only to a service the stack can address`() {
        val s = stack(container("web"))
        assertTrue(ActionPrompts.canRebuild(container("web"), s))
        assertFalse(ActionPrompts.canRebuild(container(null), s))
        assertFalse(ActionPrompts.canRebuild(container("web"), stack(container("web", workingDir = null))))
        assertNotNull(ActionPrompts.rebuild("web", s).message)
        assertEquals("Rebuild web?", ActionPrompts.rebuild("web", s).title)
    }
}
