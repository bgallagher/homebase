package com.bgallagher.rackoon.core

enum class Risk {
    /** Only looks at the server. */
    READ,

    /** Changes something on the server. */
    MUTATE,
}

/** One thing we are about to run on a server, described for the policy and for the confirmation sheet. */
data class Intent(
    val summary: String,
    val command: String,
    val risk: Risk,
    /**
     * What the confirmation sheet shows instead of the raw command, when the command is not readable (a file save carries
     * its content encoded). Part of the intent, so a confirmation only matches this exact preview.
     */
    val preview: String? = null,
)

/**
 * Proof that the user was asked about exactly this intent. Only [ActionPolicy.confirm] makes one (the constructor is
 * module-internal), so a service cannot run a mutation by accident: it has to be handed a confirmation for the same command.
 */
class Confirmation internal constructor(val intent: Intent)

sealed class PolicyError(message: String) : Exception(message) {
    object ReadOnly : PolicyError("Read-only mode is on. Turn it off to make changes.")
    object NotConfirmed : PolicyError("This change was not confirmed.")
    object InvalidTarget : PolicyError("Refusing to run: invalid container id.")
}

/**
 * The gate every state-changing command goes through, checked in the service layer (not the UI) so no screen can bypass it.
 * Reads always pass. Mutations need read-only mode to be off and a matching confirmation.
 */
class ActionPolicy(readOnly: Boolean = false) {
    @Volatile
    var isReadOnly: Boolean = readOnly

    /** Called after the user has said yes (or immediately for actions the app treats as low-risk). */
    fun confirm(intent: Intent): Confirmation {
        if (intent.risk == Risk.MUTATE && isReadOnly) throw PolicyError.ReadOnly
        return Confirmation(intent)
    }

    /** Checked again at run time, so turning read-only on after a confirmation was minted still blocks it. */
    fun authorize(intent: Intent, confirmation: Confirmation?) {
        if (intent.risk != Risk.MUTATE) return
        if (isReadOnly) throw PolicyError.ReadOnly
        if (confirmation?.intent != intent) throw PolicyError.NotConfirmed
    }
}
