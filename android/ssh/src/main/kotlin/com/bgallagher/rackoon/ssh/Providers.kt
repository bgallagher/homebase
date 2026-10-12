package com.bgallagher.rackoon.ssh

import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.security.Security

object SshProviders {
    /**
     * Android ships a cut-down provider registered as "BC"; sshj needs the full BouncyCastle (Ed25519, curve25519...). Remove the
     * platform's and insert ours first, before the first connection. Harmless on the plain JVM. Safe to call more than once.
     */
    @Synchronized
    fun install() {
        val current = Security.getProvider("BC")
        if (current is BouncyCastleProvider && current.version >= 1.80) return
        Security.removeProvider("BC")
        Security.insertProviderAt(BouncyCastleProvider(), 1)
    }
}
