package com.bgallagher.rackoon.core

import kotlinx.serialization.Serializable

/**
 * Mirrors `Server` in spec/models.schema.json.
 * `host` is whatever SSH connects to: a hostname, an IP or a Tailscale name.
 */
@Serializable
data class Server(
    val id: String,
    val name: String,
    val host: String,
    val user: String? = null,
    val port: Int? = null,
    /** Set when the server was imported from ~/.ssh/config on a Mac (the alias is `host`). Unused on Android. */
    val sshConfigAlias: String? = null,
    /** A private key file the Mac passes to ssh as `-i`. Unused on Android, which keeps keys in its encrypted store. */
    val identityFile: String? = null,
) {
    /** The `[user@]host` form. */
    val sshDestination: String get() = if (!user.isNullOrEmpty()) "$user@$host" else host

    /**
     * True when both describe the same connection: everything but the id and the display name. A saved edit that only
     * renames a server must not reconnect it.
     */
    fun connectsLike(other: Server): Boolean =
        host == other.host && user == other.user && port == other.port &&
            sshConfigAlias == other.sshConfigAlias && identityFile == other.identityFile
}
