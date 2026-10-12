package com.bgallagher.rackoon.core

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class BookmarkEditorTests {
    private fun container(service: String, bookmark: Bookmark? = null, project: String? = "media") = DockerContainer(
        id = "abcdef0123" + service.take(2).padEnd(2, 'a').map { 'a' + (it.code % 6) }.joinToString(""), name = "media-$service-1", image = "img", state = "running", health = "none",
        status = "Up", ports = emptyList(), project = project, service = service, workingDir = "/srv/media",
        configFile = "/srv/media/compose.yaml", configFiles = listOf("/srv/media/compose.yaml"), bookmark = bookmark,
    )

    private fun stack(vararg cs: DockerContainer) = DockerStack("media", "/srv/media", "/srv/media/compose.yaml", listOf("/srv/media/compose.yaml"), cs.toList(), false)

    /** A `file_read` output for this text, built the way the server does. */
    private fun fileOutput(text: String): String {
        val sha = "d".repeat(64)
        return "##meta\n1700000000 644 root:root\n##sha256\n$sha\n##content\n${java.util.Base64.getEncoder().encodeToString(text.toByteArray())}\n"
    }

    private fun session(vararg outputs: String, stack: DockerStack = stack(container("web"))) =
        StackFileSession(FakeTransport(outputs.map { ok(it) }), stack)

    private val yaml = "services:\n  web:\n    image: nginx\n"

    @Test fun `plans an edit for the service`() = runBlocking {
        val s = stack(container("web"))
        val plan = BookmarkEditor.plan(session(fileOutput(yaml), stack = s), s, "web", Bookmark(href = "http://web").labelChanges, false, "homelab")
        val edit = (plan as BookmarkPlan.Ready).edit
        assertEquals("/srv/media/compose.yaml", edit.file.path)
        assertEquals(yaml + "    labels:\n      - homepage.href=http://web\n", edit.content.removeSuffix("\n") + "\n")
        assertEquals("d".repeat(64), edit.originalSHA)
    }

    @Test fun `says so when nothing would change`() = runBlocking {
        val s = stack(container("web"))
        val plan = BookmarkEditor.plan(session(fileOutput(yaml), stack = s), s, "web", Bookmark.removalChanges, true, "homelab")
        assertEquals("web has no bookmark labels to remove.", (plan as BookmarkPlan.Notice).text)
    }

    @Test fun `says why when the file cannot be edited or read`() = runBlocking {
        val s = stack(container("web"))
        val inline = BookmarkEditor.plan(session(fileOutput("services: {}\n"), stack = s), s, "web", Bookmark(href = "http://web").labelChanges, false, "homelab")
        assertEquals("No compose file of media defines a service called web.", (inline as BookmarkPlan.Notice).text)
        val missing = BookmarkEditor.plan(session("##missing\n", stack = s), s, "web", Bookmark(href = "http://web").labelChanges, false, "homelab")
        assertEquals("Couldn't read the stack's compose file: compose.yaml is missing on homelab.", (missing as BookmarkPlan.Notice).text)
        val merge = "services:\n  web:\n    <<: *base\n    image: x\n"
        val mergeNotice = BookmarkEditor.plan(session(fileOutput(merge), stack = s), s, "web", Bookmark(href = "http://web").labelChanges, false, "homelab")
        assertTrue((mergeNotice as BookmarkPlan.Notice).text.contains("merge key"))
    }

    @Test fun `bookmark lists come from the snapshot`() {
        val a = container("web", Bookmark(href = "http://web", name = "Web", group = "Media"))
        val b = container("db")
        val c = container("solo", Bookmark(href = "https://solo.example.com", group = "apps"), project = null)
        val snap = DockerSnapshot(listOf(a, b, c))
        assertEquals(listOf("Web", "solo"), snap.bookmarkItems.map { it.title })
        assertEquals(listOf("apps", "Media"), snap.bookmarkGroups)
        assertEquals(listOf("db", "web"), snap.stacks.first { it.name == "media" }.serviceNames)
        assertEquals(listOf("media"), snap.bookmarkableStacks.map { it.name })
    }
}
