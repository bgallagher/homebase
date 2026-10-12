package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ComposeLabelsTests {
    private val bookmark = Bookmark(href = "https://aiostreams.xrray.net/", name = "AIOStreams", group = "Media")

    private fun set(b: Bookmark?, text: String, service: String = "web") =
        ComposeLabels.setting(b?.labelChanges ?: Bookmark.removalChanges, service, text)

    @Test fun `adds a labels block to a service with none`() {
        val file = "# keep me\nservices:\n  web:\n    image: nginx\n    ports:\n      - \"80:80\"\n  db:\n    image: pg\n"
        assertEquals(
            "# keep me\nservices:\n  web:\n    image: nginx\n    ports:\n      - \"80:80\"\n    labels:\n      - homepage.group=Media\n" +
                "      - homepage.name=AIOStreams\n      - homepage.href=https://aiostreams.xrray.net/\n  db:\n    image: pg\n",
            set(bookmark, file),
        )
    }

    @Test fun `replaces adds and keeps other labels in a list block`() {
        val file = "services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n      - homepage.href=http://old\n" +
            "      - \"homepage.name=Old\"\n      - homepage.weight=5\n    restart: always\n"
        assertEquals(
            "services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n      - homepage.href=https://aiostreams.xrray.net/\n" +
                "      - homepage.name=AIOStreams\n      - homepage.weight=5\n      - homepage.group=Media\n    restart: always\n",
            set(bookmark, file),
        )
    }

    @Test fun `map style labels`() {
        val file = "services:\n  web:\n    image: nginx\n    labels:\n      traefik.enable: \"true\"\n      homepage.href: http://old\n"
        assertEquals(
            "services:\n  web:\n    image: nginx\n    labels:\n      traefik.enable: \"true\"\n      homepage.href: https://aiostreams.xrray.net/\n" +
                "      homepage.group: Media\n      homepage.name: AIOStreams\n",
            set(bookmark, file),
        )
    }

    @Test fun `removing the bookmark keeps other labels or drops an empty block`() {
        val withOther = "services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n      - homepage.href=http://x\n      - homepage.name=X\n"
        assertEquals("services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n", set(null, withOther))
        val only = "services:\n  web:\n    image: nginx\n    labels:\n      - homepage.href=http://x\n    restart: always\n"
        assertEquals("services:\n  web:\n    image: nginx\n    restart: always\n", set(null, only))
        val none = "services:\n  web:\n    image: nginx\n"
        assertEquals(none, set(null, none), "nothing to remove: unchanged")
    }

    @Test fun `follows the files indentation and targets the right service`() {
        val file = "services:\n    db:\n        image: pg\n    web:\n        image: nginx\n"
        assertEquals(
            "services:\n    db:\n        image: pg\n    web:\n        image: nginx\n        labels:\n            - homepage.href=http://web\n",
            set(Bookmark(href = "http://web"), file),
        )
        assertEquals(
            "services:\n    db:\n        image: pg\n        labels:\n            - homepage.href=http://db\n    web:\n        image: nginx\n",
            set(Bookmark(href = "http://db"), file, service = "db"),
        )
    }

    @Test fun `refuses what it cannot edit safely`() {
        fun fails(text: String, expected: ComposeLabelsError, service: String = "web") {
            assertEquals(expected, assertFailsWith<ComposeLabelsError> { ComposeLabels.setting(bookmark.labelChanges, service, text) })
        }
        fails("services:\n  web:\n    image: x\n", ComposeLabelsError.ServiceNotFound("nope"), service = "nope")
        fails("services: {}\n", ComposeLabelsError.InlineServices)
        fails("volumes:\n  d: {}\n", ComposeLabelsError.ServiceNotFound("web"))
        fails("services:\n  web:\n    image: x\n    labels: {a: b}\n", ComposeLabelsError.FlowLabels("web"))
        fails("services:\n  web:\n    <<: *base\n    image: x\n", ComposeLabelsError.MergeKey("web"))
    }

    @Test fun `quoting and dollar signs`() {
        val b = Bookmark(href = "https://x.com/?a=1", name = "Plex: Media", description = "50% off #1 \$HOME")
        val out = set(b, "services:\n  web:\n    image: x\n")
        assertTrue(out.contains("- \"homepage.name=Plex: Media\""), out)
        assertTrue(out.contains("- \"homepage.description=50% off #1 \$\$HOME\""), out)
        assertTrue(out.contains("- homepage.href=https://x.com/?a=1"), out)
    }

    @Test fun `list dashes at the same indent as the labels key`() {
        val file = "services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    - homepage.href=http://old\n    restart: always\n"
        assertEquals(
            "services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    - homepage.href=http://new\n    - homepage.name=N\n    restart: always\n",
            set(Bookmark(href = "http://new", name = "N"), file),
        )
        assertEquals("services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    restart: always\n", set(null, file))
        val only = "services:\n  web:\n    image: nginx\n    labels:\n    - homepage.href=http://old\n    restart: always\n"
        assertEquals("services:\n  web:\n    image: nginx\n    restart: always\n", set(null, only))
        // The block ends at the next sibling key, which is not a dash line.
        val last = "services:\n  web:\n    image: nginx\n    labels:\n    - a=b\n  db:\n    image: pg\n"
        assertEquals(
            "services:\n  web:\n    image: nginx\n    labels:\n    - a=b\n    - homepage.href=http://x\n  db:\n    image: pg\n",
            set(Bookmark(href = "http://x"), last),
        )
    }

    @Test fun `removing the last label keeps comments and blank lines that follow`() {
        val file = "services:\n  web:\n    image: nginx\n    labels:\n      - homepage.href=http://x\n\n# footer comment\nvolumes:\n  d: {}\n"
        assertEquals("services:\n  web:\n    image: nginx\n\n# footer comment\nvolumes:\n  d: {}\n", set(null, file))
        val atEnd = "services:\n  web:\n    image: nginx\n    labels:\n      - homepage.href=http://x\n# external edit\n"
        assertEquals("services:\n  web:\n    image: nginx\n# external edit\n", set(null, atEnd))
        // Adding to a block followed by a comment puts the new label before the comment.
        assertEquals(
            "services:\n  web:\n    image: nginx\n    labels:\n      - a=b\n      - homepage.href=http://y\n# note\n",
            set(Bookmark(href = "http://y"), "services:\n  web:\n    image: nginx\n    labels:\n      - a=b\n# note\n"),
        )
    }

    @Test fun `defines service`() {
        val t = "services:\n  web:\n    image: x\n"
        assertTrue(ComposeLabels.definesService("web", t))
        assertFalse(ComposeLabels.definesService("db", t))
    }

    @Test fun `label changes drop empty fields`() {
        val changes = Bookmark(href = " https://x.com ", name = "X", group = "", icon = null, description = "  ").labelChanges
        assertEquals(Bookmark.labelKeys, changes.map { it.key })
        assertEquals(listOf(null, "X", null, "https://x.com", null), changes.map { it.value })
        assertTrue(Bookmark.removalChanges.all { it.value == null })
    }
}
