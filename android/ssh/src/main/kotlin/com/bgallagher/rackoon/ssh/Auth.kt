package com.bgallagher.rackoon.ssh

/** How to sign in. The secret parts never leave this object: the app keeps them encrypted and builds one when connecting. */
sealed class SshAuth {
    /** Tailscale SSH: the server identifies the tailnet node, so SSH `none` authentication is accepted. Nothing to store. */
    object TailscaleNone : SshAuth()

    class Password(val password: String) : SshAuth() {
        override fun toString() = "Password(***)"
    }

    /** An OpenSSH (or PEM) private key as text, with its passphrase if it has one. */
    class PrivateKey(val pem: String, val passphrase: String? = null) : SshAuth() {
        override fun toString() = "PrivateKey(***)"
    }
}

/** Where and as whom to connect. `host` is exactly what the user typed (a name, an address or a Tailscale name). */
data class SshEndpoint(val host: String, val port: Int = 22, val user: String, val auth: SshAuth) {
    companion object {
        /** Parses `user@host`, `user@host:port` or `host` (the user then comes from `defaultUser`). Null if it makes no sense. */
        fun parse(text: String, defaultUser: String = "root", auth: SshAuth = SshAuth.TailscaleNone): SshEndpoint? {
            val t = text.trim()
            if (t.isEmpty() || t.any { it.isWhitespace() }) return null
            val user = if (t.contains('@')) t.substringBefore('@') else defaultUser
            var host = if (t.contains('@')) t.substringAfter('@') else t
            var port = 22
            // `host:port`, but leave bare IPv6 addresses (several colons) alone.
            if (host.count { it == ':' } == 1) {
                port = host.substringAfter(':').toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
                host = host.substringBefore(':')
            }
            if (user.isEmpty() || host.isEmpty()) return null
            return SshEndpoint(host, port, user, auth)
        }
    }
}
