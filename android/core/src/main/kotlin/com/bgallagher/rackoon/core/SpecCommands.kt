package com.bgallagher.rackoon.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Every shell command we run on a server, read from `spec/commands.json` (copied into this module's resources at build
 * time). The Swift core keeps a duplicate string per command and tests it against the same file; here there is no copy.
 */
object SpecCommands {
    private val scripts: Map<String, String> by lazy {
        val text = SpecCommands::class.java.getResourceAsStream("/spec/commands.json")?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: error("spec/commands.json is missing from the module resources")
        val commands = (Json.parseToJsonElement(text) as JsonObject)["commands"] as JsonArray
        commands.associate { c ->
            val o = c as JsonObject
            o["id"]!!.jsonPrimitive.content to o["script"]!!.jsonPrimitive.content
        }
    }

    fun script(id: String): String = scripts[id] ?: error("no command '$id' in spec/commands.json")

    val ids: Set<String> get() = scripts.keys
}
