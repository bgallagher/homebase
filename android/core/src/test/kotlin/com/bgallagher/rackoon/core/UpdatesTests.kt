package com.bgallagher.rackoon.core

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class UpdatesParserTests {
    private fun golden(text: String): JsonElement = try {
        Json.parseToJsonElement(Spec.json.encodeToString(UpdatesParser.parse(text)))
    } catch (e: UpdatesParseError.NotInstalled) {
        JsonObject(mapOf("error" to JsonPrimitive("notInstalled")))
    } catch (e: Exception) {
        JsonObject(mapOf("error" to JsonPrimitive("other"), "message" to JsonPrimitive(e.toString())))
    }

    @Test fun everyUpdatesFixtureMatchesItsGoldenFile() {
        val names = Spec.fixtures("updates")
        assertTrue(names.size >= 4)
        for (name in names) assertJsonEquals(Spec.expected("updates", name), golden(Spec.out("updates", name)), "updates/$name")
    }

    @Test fun securityIsDecidedBySuiteNotPackageName() {
        val s = UpdatesParser.parse(Spec.out("updates", "synthetic-debian-minimal"))
        assertEquals(listOf("curl", "bash", "foo-security-tools"), s.packages.map { it.name })
        assertEquals(listOf(true, false, false), s.packages.map { it.isSecurity })
        assertEquals(1, s.securityCount)
        assertNull(s.packages[1].oldVersion, "a line without 'upgradable from' still parses")
    }

    @Test fun securityPendingFixtureCounts() {
        val s = UpdatesParser.parse(Spec.out("updates", "synthetic-security-pending"))
        assertEquals(6, s.packages.size)
        assertEquals(3, s.securityCount, "openssl, libssl3t64 and the infra-security client")
        assertEquals(listOf("linux-image-generic", "docker-ce"), s.held)
        assertTrue(s.rebootRequired)
        assertEquals("3.0.13-0ubuntu3.4", s.packages.first().oldVersion)
    }

    @Test fun missingAptSectionIsMalformed() {
        val e = assertFailsWith<UpdatesParseError.Malformed> { UpdatesParser.parse("##held\n") }
        assertEquals("no ##apt section", e.detail)
    }
}
