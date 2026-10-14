package com.bgallagher.rackoon.core

import com.bgallagher.rackoon.core.ConnectionFailure.Kind
import com.bgallagher.rackoon.core.ConnectionFailure.SignIn
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ConnectionFailureTests {
    @Test fun refusedLoginIsExplainedPerSignInMethod() {
        val raw = "Sign-in was refused: Exhausted available authentication methods"
        val tailscale = assertNotNull(ConnectionFailure.explain(raw, SignIn.Tailscale))
        val key = assertNotNull(ConnectionFailure.explain(raw, SignIn.Key))
        val password = assertNotNull(ConnectionFailure.explain(raw, SignIn.Password))
        assertEquals(Kind.AuthRefused, key.kind)
        assertTrue(tailscale.advice.contains("Tailscale SSH did not let this user in"), tailscale.advice)
        assertTrue(key.advice.contains("authorized_keys"), key.advice)
        assertTrue(password.advice.contains("PasswordAuthentication no"), password.advice)
        assertTrue(listOf(tailscale, key, password).all { it.advice.contains("Edit connection") })
        assertEquals(3, setOf(tailscale.advice, key.advice, password.advice).size)
    }

    @Test fun refusedLoginWithoutAMethodStillGivesAdvice() {
        val f = assertNotNull(ConnectionFailure.explain("Permission denied (publickey)."))
        assertEquals(Kind.AuthRefused, f.kind)
        assertTrue(f.advice.contains("user name"))
    }

    @Test fun networkFailuresAreExplained() {
        assertEquals(Kind.Unreachable, ConnectionFailure.explain("Could not reach the server: timed out")?.kind)
        assertEquals(Kind.Unreachable, ConnectionFailure.explain("Could not reach the server: failed to connect: No route to host")?.kind)
        assertEquals("Nothing accepts SSH at that address and port.", ConnectionFailure.explain("Could not reach the server: Connection refused")?.headline)
        assertEquals(Kind.Unreachable, ConnectionFailure.explain("Connection lost: Connection reset")?.kind)
        assertEquals(Kind.Unresolved, ConnectionFailure.explain("Could not reach the server: Unable to resolve host \"nas.local\": No address associated with hostname")?.kind)
    }

    @Test fun unknownMessagesGetNoExplanation() {
        assertNull(ConnectionFailure.explain("Something went wrong"))
        assertNull(ConnectionFailure.explain("The host key changed since it was trusted. Connection blocked."))
    }

    @Test fun refusedLoginDoesNotMatchNetworkText() {
        assertFalse(ConnectionFailure.isAuthRefused("Could not reach the server: timed out"))
        assertTrue(ConnectionFailure.isAuthRefused("Sign-in was refused: no accepted method"))
    }
}

class ServerInputTests {
    @Test fun goodInputHasNoProblem() {
        assertNull(ServerInput.problem("vps.example.com", "", ""))
        assertNull(ServerInput.problem(" vps ", "root", "2222"))
        assertNull(ServerInput.problem("100.64.12.7", "ubuntu", " 22 "))
    }

    @Test fun hostAndUserAreChecked() {
        assertEquals("A host is needed.", ServerInput.problem("", "", ""))
        assertEquals("A host can't start with a dash.", ServerInput.problem("-oProxyCommand=evil", "", ""))
        assertEquals("A host can't contain spaces.", ServerInput.problem("two words", "", ""))
        assertEquals("A user name can't start with a dash.", ServerInput.problem("h", "-v", ""))
        assertEquals("A user name can't contain spaces or @.", ServerInput.problem("h", "me@there", ""))
    }

    @Test fun portMustBeInRange() {
        assertNotNull(ServerInput.problem("h", "", "0"))
        assertNotNull(ServerInput.problem("h", "", "65536"))
        assertNotNull(ServerInput.problem("h", "", "ssh"))
        assertNull(ServerInput.problem("h", "", "65535"))
    }
}

class ServerConnectsLikeTests {
    @Test fun connectsLikeIgnoresTheNameOnly() {
        val a = Server("1", "lab", "h", "u", 22, identityFile = "~/.ssh/k")
        assertTrue(a.connectsLike(a.copy(name = "renamed")))
        listOf(a.copy(host = "other"), a.copy(user = null), a.copy(port = 2222), a.copy(identityFile = null), a.copy(sshConfigAlias = "h"))
            .forEach { assertFalse(a.connectsLike(it), "$it") }
        assertNotEquals(a, a.copy(name = "renamed"))
    }
}
