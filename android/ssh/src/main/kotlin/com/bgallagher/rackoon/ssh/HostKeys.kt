package com.bgallagher.rackoon.ssh

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.KeyType
import java.io.File
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Base64

/** A server's host key as presented in a handshake. */
class HostKeyInfo(
    /** The key type as ssh names it, e.g. `ssh-ed25519`. */
    val keyType: String,
    /** The public key in ssh wire format (what `ssh-keygen` hashes). */
    val blob: ByteArray,
) {
    /** `SHA256:` + base64 without padding, the format `ssh-keygen -lf` prints. */
    val fingerprint: String
        get() = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(blob))

    /** A short algorithm name for display: "Ed25519", "RSA", "ECDSA". */
    val algorithmLabel: String
        get() = when {
            keyType.contains("ed25519") -> "Ed25519"
            keyType.contains("rsa") -> "RSA"
            keyType.contains("ecdsa") -> "ECDSA"
            else -> keyType
        }

    companion object {
        fun from(key: PublicKey): HostKeyInfo = HostKeyInfo(KeyType.fromKey(key).toString(), Buffer.PlainBuffer().putPublicKey(key).compactData)
    }
}

/** A key the user chose to trust for one server. Stored as JSON. */
@Serializable
data class TrustedHostKey(
    val keyType: String,
    /** base64 of the wire-format key, as in an OpenSSH known_hosts file. */
    val publicKey: String,
    val fingerprint: String,
    /** Epoch milliseconds when it was trusted. */
    val trustedAt: Long,
) {
    val blob: ByteArray get() = Base64.getDecoder().decode(publicKey)

    companion object {
        fun of(info: HostKeyInfo, at: Long): TrustedHostKey =
            TrustedHostKey(info.keyType, Base64.getEncoder().encodeToString(info.blob), info.fingerprint, at)
    }
}

/** What to do with a presented key. */
sealed class HostKeyVerdict {
    object Trusted : HostKeyVerdict()
    class Unknown(val presented: HostKeyInfo) : HostKeyVerdict()
    class Changed(val trusted: TrustedHostKey, val presented: HostKeyInfo) : HostKeyVerdict()
}

/** Where trusted host keys live. One key per `host:port`. */
interface KnownHosts {
    fun lookup(host: String, port: Int): TrustedHostKey?
    fun trust(host: String, port: Int, key: HostKeyInfo)
    fun forget(host: String, port: Int)

    /** Compares a presented key with what is trusted. A changed key is never "trusted" by this call. */
    fun verdict(host: String, port: Int, presented: HostKeyInfo): HostKeyVerdict {
        val trusted = lookup(host, port) ?: return HostKeyVerdict.Unknown(presented)
        return if (trusted.blob.contentEquals(presented.blob)) HostKeyVerdict.Trusted else HostKeyVerdict.Changed(trusted, presented)
    }
}

internal fun hostKeyId(host: String, port: Int) = "${host.lowercase()}:$port"

class InMemoryKnownHosts(private val clock: () -> Long = System::currentTimeMillis) : KnownHosts {
    private val keys = LinkedHashMap<String, TrustedHostKey>()
    @Synchronized override fun lookup(host: String, port: Int) = keys[hostKeyId(host, port)]
    @Synchronized override fun trust(host: String, port: Int, key: HostKeyInfo) { keys[hostKeyId(host, port)] = TrustedHostKey.of(key, clock()) }
    @Synchronized override fun forget(host: String, port: Int) { keys.remove(hostKeyId(host, port)) }
}

/** `known_hosts.json`: a map from `host:port` to the trusted key. Written atomically; a corrupt file reads as empty. */
class JsonFileKnownHosts(private val file: File, private val clock: () -> Long = System::currentTimeMillis) : KnownHosts {
    private val json = Json { prettyPrint = true }
    private var cache: MutableMap<String, TrustedHostKey>? = null

    @Synchronized private fun load(): MutableMap<String, TrustedHostKey> = cache ?: run {
        val map = try {
            if (file.exists()) json.decodeFromString<Map<String, TrustedHostKey>>(file.readText()).toMutableMap() else mutableMapOf()
        } catch (_: Exception) {
            mutableMapOf()
        }
        cache = map
        map
    }

    @Synchronized private fun save() {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(json.encodeToString(load()))
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }

    @Synchronized override fun lookup(host: String, port: Int) = load()[hostKeyId(host, port)]

    @Synchronized override fun trust(host: String, port: Int, key: HostKeyInfo) {
        load()[hostKeyId(host, port)] = TrustedHostKey.of(key, clock())
        save()
    }

    @Synchronized override fun forget(host: String, port: Int) {
        if (load().remove(hostKeyId(host, port)) != null) save()
    }
}
