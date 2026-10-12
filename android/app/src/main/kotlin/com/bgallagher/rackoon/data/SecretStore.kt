package com.bgallagher.rackoon.data

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.bgallagher.rackoon.ssh.SshAuth
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

enum class AuthKind { Tailscale, Key, Password }

/** How a server is signed in to, as saved. Only ever written encrypted (see [SecretStore]); never in servers.json. */
@Serializable
data class StoredAuth(
    val kind: AuthKind,
    val password: String? = null,
    val pem: String? = null,
    val passphrase: String? = null,
    /** The key file's name, for display only. */
    val keyName: String? = null,
) {
    fun toSshAuth(): SshAuth = when (kind) {
        AuthKind.Tailscale -> SshAuth.TailscaleNone
        AuthKind.Password -> SshAuth.Password(password.orEmpty())
        AuthKind.Key -> SshAuth.PrivateKey(pem.orEmpty(), passphrase?.takeIf { it.isNotEmpty() })
    }
}

/**
 * Passwords, private keys and passphrases, one file per server, encrypted with an AES-256-GCM key that lives in the Android
 * Keystore (hardware-backed where the phone has it) and never leaves it. Without the key the files are noise, and the key is
 * not backed up (allowBackup is off). If the key is lost (a device reset) a server just asks to sign in again.
 */
class SecretStore(private val dir: File) {
    private val json = Json { ignoreUnknownKeys = true }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build(),
        )
        return gen.generateKey()
    }

    private fun file(serverId: String) = File(dir, "secrets/${serverId.filter { it.isLetterOrDigit() || it == '-' }}.bin")

    @Synchronized fun save(serverId: String, auth: StoredAuth) {
        if (auth.kind == AuthKind.Tailscale) { remove(serverId); return }   // nothing secret to keep
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.doFinal(json.encodeToString(StoredAuth.serializer(), auth).toByteArray())
        val f = file(serverId)
        f.parentFile?.mkdirs()
        val tmp = File(f.path + ".tmp")
        tmp.writeBytes(cipher.iv + sealed)   // GCM iv is 12 bytes
        if (!tmp.renameTo(f)) { f.delete(); tmp.renameTo(f) }
    }

    /** The saved sign-in, or null when none is saved (Tailscale SSH) or it cannot be decrypted. */
    @Synchronized fun load(serverId: String): StoredAuth? = try {
        val bytes = file(serverId).takeIf { it.exists() }?.readBytes() ?: return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12)) }
        json.decodeFromString(StoredAuth.serializer(), String(cipher.doFinal(bytes, 12, bytes.size - 12)))
    } catch (_: Exception) {
        null
    }

    @Synchronized fun remove(serverId: String) { file(serverId).delete() }

    private companion object { const val ALIAS = "rackoon-secrets" }
}
