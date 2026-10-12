package com.bgallagher.rackoon.core

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class ActionPolicyTests {
    private val id = "abcdef012345"

    @Test fun readsAlwaysPassEvenInReadOnlyMode() {
        val policy = ActionPolicy(readOnly = true)
        val read = Intent("List", "docker ps", Risk.READ)
        policy.authorize(read, null)
        policy.confirm(read)
    }

    @Test fun mutationNeedsAMatchingConfirmation() {
        val policy = ActionPolicy()
        val restart = assertNotNull(DockerAction.RESTART.intent(id))
        val stop = assertNotNull(DockerAction.STOP.intent(id))
        assertFailsWith<PolicyError.NotConfirmed> { policy.authorize(restart, null) }
        // A confirmation for one command cannot be reused for another.
        val confirmedStop = policy.confirm(stop)
        assertFailsWith<PolicyError.NotConfirmed> { policy.authorize(restart, confirmedStop) }
        policy.authorize(stop, confirmedStop)
    }

    @Test fun readOnlyBlocksNewAndAlreadyMintedConfirmations() {
        val policy = ActionPolicy()
        val intent = assertNotNull(DockerAction.STOP.intent(id))
        val confirmation = policy.confirm(intent)
        policy.isReadOnly = true
        assertFailsWith<PolicyError.ReadOnly> { policy.confirm(intent) }
        assertFailsWith<PolicyError.ReadOnly> { policy.authorize(intent, confirmation) }
        policy.isReadOnly = false
        policy.authorize(intent, confirmation)
    }

    @Test fun dockerActionIsBlockedInReadOnlyModeAndNothingIsSent() = runTest {
        val transport = FakeTransport()
        val session = DockerSession(transport, policy = ActionPolicy(readOnly = true))
        assertFailsWith<PolicyError.ReadOnly> { session.confirm(DockerAction.STOP, id) }
        session.perform(DockerAction.STOP, id, null)
        assertTrue(transport.commands.isEmpty())
        assertEquals(PolicyError.ReadOnly.message, session.state.value.actionError)
    }

    @Test fun dockerActionWithoutConfirmationIsRefused() = runTest {
        val transport = FakeTransport()
        val session = DockerSession(transport)
        session.perform(DockerAction.RESTART, id, null)
        assertTrue(transport.commands.isEmpty())
        assertEquals(PolicyError.NotConfirmed.message, session.state.value.actionError)
    }

    @Test fun invalidContainerIDCannotBeConfirmed() {
        val session = DockerSession(FakeTransport())
        assertFailsWith<PolicyError.InvalidTarget> { session.confirm(DockerAction.STOP, "x; reboot") }
    }
}
