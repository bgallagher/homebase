package com.bgallagher.rackoon.core

/**
 * A failed connection explained for the Overview: what the error means and what to do about it. The raw message stays on
 * screen beside it, so nothing is hidden. Pure; mirrors `ConnectionFailure` in the Swift core, except that Android has no
 * ssh binary to ask which keys were offered, so a refused login is explained from how the server is signed in to.
 */
data class ConnectionFailure(val kind: Kind, val headline: String, val advice: String) {
    enum class Kind {
        /** The server refused the credentials. */
        AuthRefused,

        /** Nothing answered at that address and port, or the link dropped. */
        Unreachable,

        /** The name did not resolve. */
        Unresolved,
    }

    /** How Rackoon signs in to the server (the app's `AuthKind`, which lives in the UI module). */
    enum class SignIn { Tailscale, Key, Password }

    companion object {
        /** True for "Sign-in was refused: …" and the messages sshj and OpenSSH use for a refused login. */
        fun isAuthRefused(message: String): Boolean =
            listOf("Sign-in was refused", "Exhausted available authentication", "Permission denied", "Authentication failed")
                .any { message.contains(it, ignoreCase = true) }

        /** Null when the message is not one we know; the card then shows the raw text alone. */
        fun explain(raw: String, signIn: SignIn? = null): ConnectionFailure? {
            val text = raw.trim()
            if (isAuthRefused(text)) return authRefused(signIn)
            if (listOf("Unable to resolve host", "UnknownHost", "No address associated with hostname", "Name or service not known",
                    "nodename nor servname provided", "Temporary failure in name resolution").any { text.contains(it, ignoreCase = true) }
            ) {
                return ConnectionFailure(
                    Kind.Unresolved, "The server's name could not be looked up.",
                    "This phone does not know that name. Check the spelling under Edit connection, or use the IP address. " +
                        "A Tailscale name only resolves while Tailscale is connected.",
                )
            }
            if (listOf("Connection refused", "ECONNREFUSED").any { text.contains(it, ignoreCase = true) }) {
                return ConnectionFailure(
                    Kind.Unreachable, "Nothing accepts SSH at that address and port.",
                    "The machine answered, but no SSH service is listening there. Check the port under Edit connection and that sshd is running on the server.",
                )
            }
            if (listOf("Connection closed", "Connection reset", "Connection lost", "EOF", "Broken pipe").any { text.contains(it, ignoreCase = true) }) {
                return ConnectionFailure(
                    Kind.Unreachable, "The server dropped the connection.",
                    "It may be rate-limiting this phone (fail2ban), restarting, or not an SSH server at all. Try again in a minute; if it keeps happening, check the address and port under Edit connection.",
                )
            }
            if (listOf("No route to host", "Network is unreachable", "timed out", "Timed out", "ENETUNREACH", "EHOSTUNREACH").any { text.contains(it) }) {
                return ConnectionFailure(
                    Kind.Unreachable, "Can't reach the server.",
                    "Check that the server is on and that this phone is on the same network or VPN (Tailscale), then try again. The address and port can be changed under Edit connection.",
                )
            }
            return null
        }

        private fun authRefused(signIn: SignIn?): ConnectionFailure {
            val advice = when (signIn) {
                SignIn.Tailscale ->
                    "Tailscale SSH did not let this user in. Check that this phone is connected to Tailscale, that your tailnet policy allows SSH to this server as this user, " +
                        "and that the user name is right (Edit connection). Or choose a key or a password under Sign-in."
                SignIn.Key ->
                    "The server did not accept the saved key for this user. Check the user name under Edit connection and that the key's public half is in the server's " +
                        "~/.ssh/authorized_keys, or choose another key under Sign-in."
                SignIn.Password ->
                    "The server did not accept the saved password for this user. Check the user name and password under Edit connection. " +
                        "Many servers also turn password login off (PasswordAuthentication no) and only take keys."
                null ->
                    "Check the user name under Edit connection, and the sign-in method: Tailscale SSH, a private key or a password."
            }
            return ConnectionFailure(Kind.AuthRefused, "The server refused the login.", advice)
        }
    }
}

/** Checks what the Edit form typed before it becomes a `Server`. Same rules and wording as `ServerInput` in the Swift core. */
object ServerInput {
    /** Why the fields can't be saved, in the user's words, or null when they can. A blank user or port is fine (root and 22). */
    fun problem(host: String, user: String, port: String): String? {
        val h = host.trim()
        val u = user.trim()
        val p = port.trim()
        if (h.isEmpty()) return "A host is needed."
        // The host becomes part of the connection target: a leading dash looks like an option in other tools.
        if (h.startsWith("-")) return "A host can't start with a dash."
        if (h.any { it.isWhitespace() }) return "A host can't contain spaces."
        if (u.startsWith("-")) return "A user name can't start with a dash."
        if (u.any { it.isWhitespace() } || u.contains('@')) return "A user name can't contain spaces or @."
        if (p.isNotEmpty() && p.toIntOrNull()?.let { it in 1..65535 } != true) return "The port must be a number from 1 to 65535."
        return null
    }
}
