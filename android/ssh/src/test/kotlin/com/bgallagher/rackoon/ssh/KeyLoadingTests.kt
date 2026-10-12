package com.bgallagher.rackoon.ssh

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** Real keys from ssh-keygen: the formats people actually have on their phones. */
class KeyLoadingTests {
    private fun key(name: String) = KeyLoadingTests::class.java.getResource("/keys/$name")!!.readText()

    @Test fun `loads an unencrypted Ed25519 OpenSSH key`() {
        assertEquals("EdDSA", SshKeys.load(key("t_ed25519"), null).type.toString().let { if (it == "ssh-ed25519") "EdDSA" else it })
    }

    @Test fun `loads RSA and ECDSA keys`() {
        SshKeys.load(key("t_rsa"), null)
        SshKeys.load(key("t_ecdsa"), null)
    }

    @Test fun `loads an encrypted key with the right passphrase`() {
        SshKeys.load(key("t_ed25519_pass"), "correct horse")
    }

    @Test fun `an encrypted key without a passphrase asks for one`() {
        val e = assertFailsWith<SshException.AuthFailed> { SshKeys.load(key("t_ed25519_pass"), null) }
        assertTrue("passphrase" in e.detail)
    }

    @Test fun `a wrong passphrase is reported as wrong`() {
        val e = assertFailsWith<SshException.AuthFailed> { SshKeys.load(key("t_ed25519_pass"), "nope") }
        assertEquals("The passphrase is wrong.", e.detail)
    }

    @Test fun `a public key or random text is explained`() {
        val pub = assertFailsWith<SshException.AuthFailed> { SshKeys.load("ssh-ed25519 AAAAC3Nza test", null) }
        assertTrue("public key" in pub.detail)
        val junk = assertFailsWith<SshException.AuthFailed> { SshKeys.load("hello", null) }
        assertTrue("not a private key" in junk.detail)
    }
}
