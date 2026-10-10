import Foundation
import RackoonCore
import RackoonSSHSystem
import Observation

/// Bridges UpdatesSession to SwiftUI. Reads when the screen opens and after every action; there is no background polling.
@MainActor @Observable
final class UpdatesModel {
    private(set) var state = UpdatesState()
    private(set) var loading = false
    /// An apt action is running (they take minutes, so the screen shows progress instead of freezing buttons silently).
    private(set) var working: String?
    /// A change waiting for the user's yes (shown as a sheet).
    var pending: PendingAction?

    @ObservationIgnored private let session: UpdatesSession
    @ObservationIgnored private let serverName: String

    init(server: Server) {
        serverName = server.name
        // RACKOON_DEMO_UPDATES=1 swift run RackoonMac: pretend the server has pending updates (nothing is sent to it),
        // so the screen can be seen and worked on when the real server is fully up to date.
        let transport: SSHTransport = ProcessInfo.processInfo.environment["RACKOON_DEMO_UPDATES"] != nil
            ? DemoUpdatesTransport() : OpenSSHTransport(server: server)
        session = UpdatesSession(transport: transport, policy: SafetyStore.shared.policy)
    }

    var packages: [PendingUpdate] {
        (state.snapshot?.packages ?? []).sorted { ($0.isSecurity ? 0 : 1, $0.name) < ($1.isSecurity ? 0 : 1, $1.name) }
    }
    var securityNames: [String] { packages.filter(\.isSecurity).map(\.name) }
    /// "Install security updates" needs an explicit list, which is capped; beyond the cap use Install all.
    var canInstallSecurity: Bool { !securityNames.isEmpty && securityNames.count <= AptAction.maxPackages }

    func load() {
        guard !loading, working == nil else { return }
        loading = true
        Task {
            state = await session.refresh()
            loading = false
        }
    }

    func request(_ action: AptAction) {
        guard !SafetyStore.shared.readOnly, working == nil, let intent = action.intent else { return }
        let all = packages.count, security = securityNames.count
        let (title, message, label): (String, String, String) = switch action {
        case .refresh:
            ("Refresh package lists?", "Checks the repositories for new versions. Nothing is installed.", "Refreshing package lists…")
        case .upgradeAll:
            ("Install all \(all) updates?",
             "Held packages stay as they are and existing config files are kept. Some updates may ask for a reboot afterwards.",
             "Installing \(all) updates…")
        case .upgrade(let names):
            ("Install \(security) security update\(security == 1 ? "" : "s")?",
             "Only these packages are upgraded: \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? " and \(names.count - 6) more" : "").",
             "Installing security updates…")
        }
        pending = PendingAction(title: title, message: message, serverName: serverName, command: intent.command,
                                destructive: false, run: { [weak self] in self?.run(action, label: label) })
    }

    private func run(_ action: AptAction, label: String) {
        guard working == nil else { return }
        working = label
        let session = session
        Task {
            // The same policy that vetted the request vets it again here; a switch to read-only in between wins.
            let confirmation = try? session.confirm(action)
            await session.perform(action, confirmation: confirmation)
            state = await session.state
            working = nil
        }
    }

    func dismissResult() {
        // The session keeps the last result until the next action; clear the visible copy only.
        state.actionOutput = nil
        state.actionError = nil
    }
}

/// Canned answers for the Updates screen. Never talks to a server.
private struct DemoUpdatesTransport: SSHTransport {
    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        if command == UpdatesSession.command {
            return CommandResult(stdout: """
            ##apt
            ok
            ##upgradable
            Listing...
            openssl/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]
            libssl3t64/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]
            libc6/noble-updates 2.39-0ubuntu8.4 amd64 [upgradable from: 2.39-0ubuntu8.3]
            linux-image-generic/noble-updates 6.8.0-52.53 amd64 [upgradable from: 6.8.0-51.52]
            docker-ce/noble 5:27.5.1-1~ubuntu.24.04~noble amd64 [upgradable from: 5:27.4.0-1~ubuntu.24.04~noble]
            ##held
            docker-ce
            ##refreshed
            1735689600
            ##reboot
            yes
            """)
        }
        try await Task.sleep(for: .seconds(3))
        return CommandResult(stdout: "Reading package lists...\nBuilding dependency tree...\n0 upgraded (demo, nothing was run)\n")
    }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
