package com.bgallagher.rackoon.core

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DockerParserTests {
    private fun golden(text: String): JsonElement = try {
        Json.parseToJsonElement(Spec.json.encodeToString(DockerParser.parse(text)))
    } catch (e: DockerParseError.NotInstalled) {
        JsonObject(mapOf("error" to JsonPrimitive("notInstalled")))
    } catch (e: DockerParseError.Daemon) {
        JsonObject(mapOf("error" to JsonPrimitive("daemon"), "message" to JsonPrimitive(e.text)))
    } catch (e: Exception) {
        JsonObject(mapOf("error" to JsonPrimitive("other"), "message" to JsonPrimitive(e.toString())))
    }

    @Test fun everyDockerFixtureMatchesItsGoldenFile() {
        val names = Spec.fixtures("docker")
        assertTrue(names.size >= 4)
        for (name in names) assertJsonEquals(Spec.expected("docker", name), golden(Spec.out("docker", name)), "docker/$name")
    }

    @Test fun stacksGroupByProjectWithStandaloneLast() {
        val stacks = DockerParser.parse(Spec.out("docker", "synthetic-mixed-states")).stacks
        assertEquals(listOf("dockge", "monitoring", "shlink", "watchtower", "Standalone"), stacks.map { it.name })
        val monitoring = assertNotNull(stacks.firstOrNull { it.name == "monitoring" })
        assertEquals("compose.yaml", monitoring.configFileName)
        assertEquals(1, monitoring.stoppedCount, "grafana is exited in this fixture")
        assertEquals(1, monitoring.unhealthyCount, "prometheus is unhealthy in this fixture")
        assertTrue(stacks.last().isStandalone)
    }

    @Test fun ports() {
        val ports = DockerParser.parsePorts("127.0.0.1:8087->8080/tcp, [::]:8087->8080/tcp, 172.17.0.1:8087->8080/tcp, 5432/tcp, 67-68/udp, 0.0.0.0:53->53/udp, 0.0.0.0:8000-8010->8000-8010/tcp")
        assertEquals(
            listOf(DockerContainer.PortMapping(8087, 8080, "tcp"), DockerContainer.PortMapping(53, 53, "udp")), ports,
            "published only, one per host port, ranges skipped",
        )
    }

    @Test fun sizesAndPercent() {
        assertEquals(268_225_741L, DockerParser.parseSize("255.8MiB"))
        assertEquals(8_128_225_608L, DockerParser.parseSize("7.57GiB"))
        assertEquals(115_000L, DockerParser.parseSize("115kB"))
        assertEquals(0L, DockerParser.parseSize("0B"))
        assertNull(DockerParser.parseSize("lots"))
        assertEquals(0.03, DockerParser.parsePercent("0.03%"))
        assertNull(DockerParser.parsePercent("--"))
    }

    @Test fun healthFallsBackToStatusTextForOlderDocker() {
        assertEquals("healthy", DockerParser.health(null, "Up 2 hours (healthy)"))
        assertEquals("unhealthy", DockerParser.health("", "Up 1 minute (unhealthy)"))
        assertEquals("starting", DockerParser.health(null, "Up 3 seconds (health: starting)"))
        assertEquals("none", DockerParser.health(null, "Up 2 hours"))
        assertEquals("unhealthy", DockerParser.health("unhealthy", "Up"))
    }

    @Test fun labelValuesMayContainCommas() {
        val m = DockerParser.parseLabels("a=1,com.docker.compose.project.config_files=/x/a.yaml,/x/b.yaml,b=2")
        assertEquals("/x/a.yaml,/x/b.yaml", m["com.docker.compose.project.config_files"])
        assertEquals("2", m["b"])
    }

    @Test fun missingDockerSectionIsMalformed() {
        assertFailsWith<DockerParseError.Malformed> { DockerParser.parse("##ps\n") }
    }
}

class BookmarkTests {
    @Test fun onlyAUsableHrefMakesABookmark() {
        assertNull(Bookmark.from(mapOf("homepage.name" to "x")))
        for (bad in listOf("", "ftp://x.com", "javascript:alert(1)", "https://", "not a url", "https://a b.com", "file:///etc/passwd", "x.com")) {
            assertNull(Bookmark.from(mapOf("homepage.href" to bad)), bad)
        }
        for (good in listOf("http://dockge", "https://x.example.com/path?a=1#b", "http://100.64.0.1:8080")) {
            assertNotNull(Bookmark.from(mapOf("homepage.href" to good)), good)
        }
        assertNull(Bookmark.from(mapOf("homepage.href" to "https://x.com", "homepage.name" to "  "))?.name, "blank fields are absent")
    }
}
