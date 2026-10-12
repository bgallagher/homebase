package com.bgallagher.rackoon.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File

/** The language-neutral contract in `spec/`, read straight from the repository (path passed in by Gradle). */
object Spec {
    val root: File = File(System.getProperty("rackoon.spec") ?: error("rackoon.spec is not set (run the tests through Gradle)"))
    val json = Json { explicitNulls = false; encodeDefaults = true; ignoreUnknownKeys = false }

    fun file(path: String): File = File(root, path).also { require(it.exists()) { "missing spec file $path" } }
    fun text(path: String): String = file(path).readText(Charsets.UTF_8)
    fun parse(path: String): JsonElement = Json.parseToJsonElement(text(path))

    /** Names of fixtures for a command: every `NAME.out.txt` in spec/fixtures/<id>/. */
    fun fixtures(commandID: String, suffix: String = ".out.txt"): List<String> =
        file("fixtures/$commandID").listFiles { f -> f.name.endsWith(suffix) }!!.map { it.name.removeSuffix(suffix) }.sorted()

    fun out(commandID: String, name: String): String = text("fixtures/$commandID/$name.out.txt")
    fun expected(commandID: String, name: String): JsonElement = parse("fixtures/$commandID/$name.expected.json")
}

/**
 * Structural JSON equality for golden files. Numbers compare by value (1 equals 1.0), and object key order does not matter.
 * Returns a readable description of the first difference, or null when equal.
 */
fun jsonDiff(expected: JsonElement, actual: JsonElement, path: String = "$"): String? = when {
    expected is JsonObject && actual is JsonObject -> {
        val keys = (expected.keys + actual.keys).sorted()
        keys.firstNotNullOfOrNull { k ->
            val e = expected[k]
            val a = actual[k]
            when {
                e == null -> "$path.$k: unexpected key in actual ($a)"
                a == null -> "$path.$k: missing in actual (expected $e)"
                else -> jsonDiff(e, a, "$path.$k")
            }
        }
    }
    expected is JsonArray && actual is JsonArray ->
        if (expected.size != actual.size) "$path: expected ${expected.size} items, got ${actual.size}"
        else expected.indices.firstNotNullOfOrNull { jsonDiff(expected[it], actual[it], "$path[$it]") }
    expected is JsonPrimitive && actual is JsonPrimitive -> {
        val en = expected.content.toDoubleOrNull()
        val an = actual.content.toDoubleOrNull()
        when {
            expected === JsonNull || actual === JsonNull -> if (expected == actual) null else "$path: expected $expected, got $actual"
            !expected.isString && !actual.isString && en != null && an != null -> if (en == an) null else "$path: expected $en, got $an"
            expected.content == actual.content && expected.isString == actual.isString -> null
            else -> "$path: expected $expected, got $actual"
        }
    }
    else -> "$path: expected $expected, got $actual"
}

fun assertJsonEquals(expected: JsonElement, actual: JsonElement, what: String) {
    val diff = jsonDiff(expected, actual)
    if (diff != null) throw AssertionError("$what: $diff")
}
