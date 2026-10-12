package com.bgallagher.rackoon.data

import android.content.Context
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.ssh.JsonFileKnownHosts
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import com.bgallagher.rackoon.terminal.TerminalManager
import java.io.File

/** `servers.json`: the saved servers, using the core `Server` model. Written atomically; a corrupt file reads as empty. */
class ServersFile(private val file: File) {
    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }

    fun load(): List<Server> = try {
        if (file.exists()) json.decodeFromString<List<Server>>(file.readText()) else emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    fun save(servers: List<Server>) {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(json.encodeToString(servers))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }
}

/** Small preferences. Read-only starts ON: a phone is easier to mis-tap than a Mac. */
class Prefs(context: Context) {
    private val prefs = context.getSharedPreferences("rackoon", Context.MODE_PRIVATE)

    var selectedServerId: String?
        get() = prefs.getString("selected_server", null)
        set(value) = prefs.edit().putString("selected_server", value).apply()

    var readOnly: Boolean
        get() = prefs.getBoolean("read_only", true)
        set(value) = prefs.edit().putBoolean("read_only", value).apply()

    /** Colour error words, IP addresses and high percentages in terminal output (core TerminalOutputFilter). */
    var highlightOutput: Boolean
        get() = prefs.getBoolean("highlight_output", true)
        set(value) = prefs.edit().putBoolean("highlight_output", value).apply()

    /** Terminal font size in sp. A phone is about 64 columns wide in portrait at 11 sp, so the default is smaller (9 sp gives about 88). */
    var terminalFontSize: Int
        get() = prefs.getInt("terminal_font_size", 9)
        set(value) = prefs.edit().putInt("terminal_font_size", value.coerceIn(7, 20)).apply()

    var firstRunDone: Boolean
        get() = prefs.getBoolean("first_run_done", false)
        set(value) = prefs.edit().putBoolean("first_run_done", value).apply()
}

/** Everything that lives for the whole process, built once by [com.bgallagher.rackoon.RackoonApp]. */
class AppContainer(context: Context) {
    private val appContext = context.applicationContext
    private val dir = File(context.filesDir, "Rackoon")
    val servers = ServersFile(File(dir, "servers.json"))
    val knownHosts = JsonFileKnownHosts(File(dir, "known_hosts.json"))
    val prefs = Prefs(context)
    val terminals = TerminalManager(appContext, knownHosts)
}
