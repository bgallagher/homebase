package com.bgallagher.rackoon.data

import com.bgallagher.rackoon.core.Overview
import com.bgallagher.rackoon.core.ServerSession
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/** The last good Overview per server, so a server shows its previous reading at once (marked stale) while the first poll runs. */
class SnapshotStore(private val dir: File) {
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable private class Saved(val overview: Overview, val savedAt: Long)

    private fun file(serverId: String) = File(dir, "snapshots/${serverId.filter { it.isLetterOrDigit() || it == '-' }}.json")

    fun load(serverId: String): ServerSession.Cached? = try {
        val saved = json.decodeFromString(Saved.serializer(), file(serverId).takeIf { it.exists() }?.readText() ?: return null)
        ServerSession.Cached(saved.overview, saved.savedAt)
    } catch (_: Exception) {
        null
    }

    fun save(serverId: String, overview: Overview, at: Long = System.currentTimeMillis()) {
        try {
            val f = file(serverId)
            f.parentFile?.mkdirs()
            val tmp = File(f.path + ".tmp")
            tmp.writeText(json.encodeToString(Saved.serializer(), Saved(overview, at)))
            if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
        } catch (_: Exception) {
            // a cache that cannot be written is only a missed optimisation
        }
    }

    fun remove(serverId: String) { file(serverId).delete() }
}
