package com.bgallagher.rackoon.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DockerPresentationTests {
    private fun c(name: String, state: String = "running", health: String = "none", project: String? = "p") =
        DockerContainer(id = "a".repeat(12), name = name, image = "img", state = state, health = health, status = "", ports = emptyList(), project = project)

    @Test fun `link scope matches the Mac rules`() {
        assertEquals(LinkScope.LOCAL, LinkScope.of("http://dockge"))
        assertEquals(LinkScope.LOCAL, LinkScope.of("http://grafana.local:3000"))
        assertEquals(LinkScope.LOCAL, LinkScope.of("http://192.168.1.5:8080"))
        assertEquals(LinkScope.LOCAL, LinkScope.of("http://172.20.0.4"))
        assertEquals(LinkScope.PUBLIC, LinkScope.of("http://172.40.0.4"))
        assertEquals(LinkScope.TAILSCALE, LinkScope.of("https://immich.tailnet-name.ts.net"))
        assertEquals(LinkScope.TAILSCALE, LinkScope.of("http://100.125.183.84:9090"))
        assertEquals(LinkScope.PUBLIC, LinkScope.of("http://100.200.1.1"))
        assertEquals(LinkScope.PUBLIC, LinkScope.of("https://aiometadata.example.com"))
        assertEquals(LinkScope.PUBLIC, LinkScope.of("not a url"))
    }

    @Test fun `stack status picks the most serious thing`() {
        fun stack(vararg cs: DockerContainer) = DockerStack("p", null, null, emptyList(), cs.toList(), false)
        assertEquals(StackStatus("1 unhealthy", StackSeverity.DANGER), stack(c("a", health = "unhealthy"), c("b")).status())
        assertEquals(StackStatus("Not started", StackSeverity.IDLE), stack().status())
        assertEquals(StackStatus("Stopped", StackSeverity.IDLE), stack(c("a", state = "exited")).status())
        assertEquals(StackStatus("1 stopped", StackSeverity.WARNING), stack(c("a"), c("b", state = "exited")).status())
        assertEquals(StackStatus("", StackSeverity.OK), stack(c("a"), c("b")).status())
    }

    @Test fun `summary counts stacks and containers`() {
        val snap = DockerSnapshot(listOf(c("a"), c("b", health = "unhealthy"), c("c", project = null), c("d", state = "exited")))
        assertEquals("1 stack · 4 containers · 3 running, 1 stopped, 1 unhealthy", snap.summary())
        assertEquals("1 container · 1 running", DockerSnapshot(listOf(c("x", project = null))).summary())
    }

    @Test fun `letter tile hue is stable and in range`() {
        assertEquals("D", LetterTile.letter("dockge"))
        assertEquals("?", LetterTile.letter(""))
        assertEquals(LetterTile.hue("immich"), LetterTile.hue("immich"))
        assertEquals(LetterTile.slot("immich", 6), LetterTile.slot("immich", 6), "a stack keeps its colour")
        assertTrue(listOf("immich", "dockge", "grafana", "Ünï", "").all { LetterTile.slot(it, 6) in 0..5 })
        for (n in listOf("a", "monitoring", "cloudflared", "watchtower", "ü")) assert(LetterTile.hue(n) in 0 until 360)
        // djb2: "a" = 5381*33 + 97 = 177670; 177670 % 360 = 190
        assertEquals(190, LetterTile.hue("a"))
    }

    @Test fun `usage text`() {
        val fmt = { b: Long -> "$b B" }
        assertEquals("6% · 147 B", c("a").copy(cpuPercent = 5.6, memoryUsedBytes = 147).usageText(fmt))
        assertEquals("—", c("a").usageText(fmt))
        assertEquals("exited", c("a", state = "exited").usageText(fmt))
    }
}
