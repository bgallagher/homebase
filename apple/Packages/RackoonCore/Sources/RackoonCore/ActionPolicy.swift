import Foundation

public enum Risk: Sendable, Equatable {
    /// Only looks at the server.
    case read
    /// Changes something on the server.
    case mutate
}

/// One thing we are about to run on a server, described for the policy and for the confirmation dialog.
public struct Intent: Sendable, Equatable {
    public let summary: String
    public let command: String
    public let risk: Risk
    /// What the confirmation dialog shows instead of the raw command, when the command is not readable
    /// (a file save carries its content encoded). Part of the intent, so a confirmation only matches this exact preview.
    public let preview: String?

    public init(summary: String, command: String, risk: Risk, preview: String? = nil) {
        self.summary = summary
        self.command = command
        self.risk = risk
        self.preview = preview
    }
}

/// Proof that the user was asked about exactly this intent. Only `ActionPolicy.confirm` makes one, so a
/// service cannot run a mutation by accident: it has to be handed a confirmation for the same command.
public struct Confirmation: Sendable, Equatable {
    public let intent: Intent
    fileprivate init(intent: Intent) { self.intent = intent }
}

public enum PolicyError: Error, LocalizedError, Equatable {
    case readOnly
    case notConfirmed
    case invalidTarget

    public var errorDescription: String? {
        switch self {
        case .readOnly: "Read-only mode is on. Turn it off to make changes."
        case .notConfirmed: "This change was not confirmed."
        case .invalidTarget: "Refusing to run: invalid container id."
        }
    }
}

/// The gate every state-changing command goes through, checked in the service layer (not the UI) so no
/// screen can bypass it. Reads always pass. Mutations need read-only mode to be off and a matching confirmation.
public final class ActionPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var readOnly: Bool

    public init(readOnly: Bool = false) { self.readOnly = readOnly }

    public var isReadOnly: Bool {
        get { lock.withLock { readOnly } }
        set { lock.withLock { readOnly = newValue } }
    }

    /// Called after the user has said yes (or immediately for actions the app treats as low-risk).
    public func confirm(_ intent: Intent) throws -> Confirmation {
        if intent.risk == .mutate, isReadOnly { throw PolicyError.readOnly }
        return Confirmation(intent: intent)
    }

    /// Checked again at run time, so turning read-only on after a confirmation was minted still blocks it.
    public func authorize(_ intent: Intent, with confirmation: Confirmation?) throws {
        guard intent.risk == .mutate else { return }
        if isReadOnly { throw PolicyError.readOnly }
        guard confirmation?.intent == intent else { throw PolicyError.notConfirmed }
    }
}
