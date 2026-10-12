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

/** Reading private keys the user imports. A key we cannot use is reported in plain words, before any connection. */
object SshKeys {
    /** Loads an OpenSSH or PEM private key. Throws [SshException.AuthFailed] saying what is wrong (needs a passphrase, wrong passphrase, not a key). */
    fun load(pem: String, passphrase: String?): net.schmizz.sshj.userauth.keyprovider.KeyProvider =
        load(net.schmizz.sshj.SSHClient(), pem, passphrase)

    internal fun load(ssh: net.schmizz.sshj.SSHClient, pem: String, passphrase: String?): net.schmizz.sshj.userauth.keyprovider.KeyProvider {
        SshProviders.install()
        val text = pem.trim()
        if (!text.startsWith("-----BEGIN") || !text.contains("PRIVATE KEY")) {
            throw SshException.AuthFailed(if (text.startsWith("ssh-") || text.startsWith("ecdsa-")) "That is a public key. Choose the private key file (the one without .pub)." else "That file is not a private key.")
        }
        val encrypted = text.contains("ENCRYPTED") || isEncryptedOpenSsh(text)
        if (encrypted && passphrase.isNullOrEmpty()) throw SshException.AuthFailed("This key is protected by a passphrase. Enter it below.")
        return try {
            val finder = passphrase?.takeIf { it.isNotEmpty() }?.let { net.schmizz.sshj.userauth.password.PasswordUtils.createOneOff(it.toCharArray()) }
            val provider = ssh.loadKeys(text, null, finder)
            provider.private // forces decryption now, so a wrong passphrase fails here and not mid-connect
            provider
        } catch (e: Exception) {
            val m = (e.message ?: "").lowercase()
            throw SshException.AuthFailed(
                if (encrypted && ("passphrase" in m || "decrypt" in m || "bad" in m || "mac" in m || "padding" in m)) "The passphrase is wrong." else "That key could not be read (${e.message ?: e.javaClass.simpleName}).",
                e,
            )
        }
    }

    /** New-style OpenSSH keys say they are encrypted only inside the binary body: the cipher name after the magic is not "none". */
    private fun isEncryptedOpenSsh(text: String): Boolean {
        if (!text.contains("BEGIN OPENSSH PRIVATE KEY")) return false
        val body = text.lines().filter { !it.startsWith("-----") }.joinToString("")
        val bytes = try { java.util.Base64.getDecoder().decode(body) } catch (_: Exception) { return false }
        val magic = "openssh-key-v1\u0000".toByteArray()
        if (bytes.size < magic.size + 4 || !bytes.copyOfRange(0, magic.size).contentEquals(magic)) return false
        val n = java.nio.ByteBuffer.wrap(bytes, magic.size, 4).int
        if (n < 0 || magic.size + 4 + n > bytes.size) return false
        return String(bytes, magic.size + 4, n) != "none"
    }
}
