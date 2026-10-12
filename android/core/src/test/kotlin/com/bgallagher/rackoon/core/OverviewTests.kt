package com.bgallagher.rackoon.core

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class OverviewTests {
    @Test fun everyOverviewFixtureMatchesItsGoldenFile() {
        val names = Spec.fixtures("overview")
        assertEquals(true, names.size >= 5)
        for (name in names) {
            val parsed = OverviewParser.parse(Spec.out("overview", name))
            val actual = Json.parseToJsonElement(Spec.json.encodeToString(parsed))
            assertJsonEquals(Spec.expected("overview", name), actual, "overview/$name")
        }
    }

    @Test fun missingRequiredSectionThrows() {
        val out = Spec.out("overview", "ubuntu-24.04").replace("##loadavg", "##notloadavg")
        assertFailsWith<ParseError.MissingSection> { OverviewParser.parse(out) }
    }

    @Test fun ipv4OnlyAcceptsDottedQuads() {
        assertEquals("100.64.1.2", OverviewParser.ipv4(" 100.64.1.2 "))
        assertNull(OverviewParser.ipv4("300.1.1.1"))
        assertNull(OverviewParser.ipv4("fe80::1"))
        assertNull(OverviewParser.ipv4("1.2.3"))
        assertNull(OverviewParser.ipv4(null))
    }

    @Test fun cpuPercentFromTwoReadings() {
        val a = OverviewParser.parse(Spec.out("overview", "ubuntu-24.04"))
        val b = a.copy(cpu = Overview.CPUCounters(total = a.cpu.total + 1000, idle = a.cpu.idle + 750))
        assertEquals(25.0, assertNotNull(b.cpuPercent(since = a)), 1e-9)
        assertNull(a.cpuPercent(since = a), "no time passed")
    }

    @Test fun serialisesWithoutNullsSoOlderSnapshotsStayCompatible() {
        val o = OverviewParser.parse(Spec.out("overview", "ubuntu-24.04"))
        val text = Spec.json.encodeToString(o)
        assertEquals(false, text.contains("null"))
    }
}
