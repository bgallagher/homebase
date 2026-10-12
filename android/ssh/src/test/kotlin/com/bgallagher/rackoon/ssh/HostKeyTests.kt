package com.bgallagher.rackoon.ssh

import java.io.File
import java.nio.file.Files
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HostKeyTests {
    /** Keys generated with ssh-keygen, with the fingerprints `ssh-keygen -lf` printed for them. */
    private fun fromLine(line: String): HostKeyInfo {
        val (type, b64) = line.split(' ')
        return HostKeyInfo(type, Base64.getDecoder().decode(b64))
    }

    private val ed25519 = fromLine("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEyGyUFkH3BGs3cx7DNxG9/1PKihMHs6TGgFyU01Qpz9")

    @Test fun fingerprintMatchesSshKeygen() {
        assertEquals("SHA256:XJxmt/YQHgzloTSoo+L3aRByH4hKuQjhvNTee3Su76o", ed25519.fingerprint)
        assertEquals("Ed25519", ed25519.algorithmLabel)
    }

    @Test fun anotherKeyHasAnotherFingerprint() {
        val other = HostKeyInfo("ssh-ed25519", ed25519.blob.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() })
        assertTrue(other.fingerprint != ed25519.fingerprint)
    }

    @Test fun verdictsTellUnknownTrustedAndChangedApart() {
        val store = InMemoryKnownHosts()
        assertTrue(store.verdict("h", 22, ed25519) is HostKeyVerdict.Unknown)
        store.trust("h", 22, ed25519)
        assertTrue(store.verdict("h", 22, ed25519) is HostKeyVerdict.Trusted)
        assertTrue(store.verdict("H", 22, ed25519) is HostKeyVerdict.Trusted, "host names compare case-insensitively")
        assertTrue(store.verdict("h", 2222, ed25519) is HostKeyVerdict.Unknown, "another port is another server")
        val changed = HostKeyInfo("ssh-ed25519", ed25519.blob.copyOf().also { it[10] = (it[10].toInt() xor 1).toByte() })
        val verdict = store.verdict("h", 22, changed)
        assertTrue(verdict is HostKeyVerdict.Changed)
        assertEquals(ed25519.fingerprint, (verdict as HostKeyVerdict.Changed).trusted.fingerprint)
        assertEquals(changed.fingerprint, verdict.presented.fingerprint)
        store.forget("h", 22)
        assertNull(store.lookup("h", 22))
    }

    @Test fun jsonFileStoreSurvivesARestartAndACorruptFile() {
        val dir = Files.createTempDirectory("rk-known").toFile()
        try {
            val file = File(dir, "nested/known_hosts.json")
            JsonFileKnownHosts(file) { 1_700_000_000_000 }.trust("vps", 22, ed25519)
            val again = JsonFileKnownHosts(file)
            val trusted = assertNotNull(again.lookup("vps", 22))
            assertEquals(ed25519.fingerprint, trusted.fingerprint)
            assertEquals(1_700_000_000_000, trusted.trustedAt)
            assertTrue(again.verdict("vps", 22, ed25519) is HostKeyVerdict.Trusted)
            again.forget("vps", 22)
            assertNull(JsonFileKnownHosts(file).lookup("vps", 22))
            file.writeText("not json")
            assertNull(JsonFileKnownHosts(file).lookup("vps", 22), "a corrupt file reads as empty")
        } finally {
            dir.deleteRecursively()
        }
    }
}

class EndpointTests {
    @Test fun parsesUserHostAndPort() {
        val e = SshEndpoint.parse("ubuntu@100.64.12.7")!!
        assertEquals(Triple("ubuntu", "100.64.12.7", 22), Triple(e.user, e.host, e.port))
        val p = SshEndpoint.parse(" root@vps.example.com:2222 ")!!
        assertEquals(Triple("root", "vps.example.com", 2222), Triple(p.user, p.host, p.port))
        val bare = SshEndpoint.parse("hetzner", defaultUser = "admin")!!
        assertEquals("admin", bare.user)
        assertEquals("hetzner", bare.host)
    }

    @Test fun ipv6AddressesKeepTheirColons() {
        val e = SshEndpoint.parse("root@fd7a:115c:a1e0::1")!!
        assertEquals("fd7a:115c:a1e0::1", e.host)
        assertEquals(22, e.port)
    }

    @Test fun rejectsNonsense() {
        for (bad in listOf("", "   ", "a b@c", "@host", "user@", "user@host:0", "user@host:99999", "user@host:abc")) assertNull(SshEndpoint.parse(bad), bad)
    }

    @Test fun secretsAreNeverPrinted() {
        assertEquals("Password(***)", SshAuth.Password("hunter2").toString())
        assertEquals("PrivateKey(***)", SshAuth.PrivateKey("-----BEGIN", "pw").toString())
    }
}
