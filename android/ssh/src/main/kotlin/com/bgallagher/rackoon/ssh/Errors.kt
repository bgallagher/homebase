package com.bgallagher.rackoon.ssh

/** What can go wrong reaching a server, in terms the UI can explain. */
sealed class SshException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** Could not open a connection at all (no route, refused, timed out, unknown host). */
    class Unreachable(val detail: String, cause: Throwable? = null) : SshException("Could not reach the server: $detail", cause)

    /** The server did not accept the credentials. */
    class AuthFailed(val detail: String, cause: Throwable? = null) : SshException("Sign-in was refused: $detail", cause)

    /** First connection: nothing is trusted for this server yet. Carries the key to show to the user. No credentials were sent. */
    class HostKeyUnknown(val presented: HostKeyInfo) : SshException("This server's host key is not trusted yet.")

    /** The server presented a different key than the one trusted. Never offered for acceptance. No credentials were sent. */
    class HostKeyChanged(val trusted: TrustedHostKey, val presented: HostKeyInfo) :
        SshException("The host key changed since it was trusted. Connection blocked.")

    /** An established connection dropped or failed mid-command. */
    class ConnectionLost(val detail: String, cause: Throwable? = null) : SshException("Connection lost: $detail", cause)

    /** A command did not finish in time. */
    class Timeout(val millis: Long) : SshException("The command did not finish within ${millis / 1000} s.")
}
