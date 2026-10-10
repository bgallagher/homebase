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
    /// The latest install or refresh and what apt printed, kept until closed or replaced.
    private(set) var output: ActionOutput?
    /// A change waiting for the user's yes (shown as a sheet).
    var pending: PendingAction?

    @ObservationIgnored private let session: UpdatesSession
    @ObservationIgnored private let serverName: String

    init(server: Server) {
        serverName = server.name
        // RACKOON_DEMO_UPDATES=1 swift run RackoonMac: pretend the server has pending updates (nothing is sent to it),
        // so the screen can be seen and worked on when the real server is fully up to date.
        let transport: SSHTransport = ProcessInfo.processInfo.environment["RACKOON_DEMO_UPDATES"] != nil
            ? DemoUpdatesTransport() : makeTransport(for: server)
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

    /// Runs the action with live output: apt's own progress in a terminal on the page, then the list is re-read.
    private func run(_ action: AptAction, label: String) {
        guard working == nil else { return }
        working = label
        let session = session
        let title: String
        switch action {
        case .refresh: title = "apt-get update"
        case .upgradeAll: title = "apt-get upgrade"
        case .upgrade(let names): title = "apt-get install --only-upgrade (\(names.count) package\(names.count == 1 ? "" : "s"))"
        }
        output = ActionOutput.launch(
            scope: "updates", title: title,
            work: { cols, rows, onEvent in
                // The same policy that vetted the request vets it again here; a switch to read-only in between wins.
                let confirmation = try? session.confirm(action)
                await session.performStreaming(action, confirmation: confirmation, cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in
                self?.working = nil
                Task { @MainActor in self?.state = await session.state }
            })
    }

    func cancelOutput() { output?.task?.cancel() }

    func dismissOutput() {
        guard output?.isRunning != true else { return }
        output = nil
    }
}

/// Canned answers for the Updates screen. Never talks to a server.
struct DemoUpdatesTransport: SSHTransport {
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
            \(Int(Date().timeIntervalSince1970) - 3 * 3600)
            ##reboot
            yes
            """)
        }
        try await Task.sleep(for: .seconds(3))
        return CommandResult(stdout: "Reading package lists...\nBuilding dependency tree...\n0 upgraded (demo, nothing was run)\n")
    }

    /// Fake apt output, line by line with pauses, so the live terminal can be seen working. The exit marker at the end
    /// is what a real run prints (see StreamedCommand).
    func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let lines = ["Reading package lists... Done", "Building dependency tree... Done",
                             "The following packages will be upgraded:", "  libssl3t64 openssl", "2 upgraded, 0 newly installed, 0 to remove.",
                             "Get:1 http://archive.ubuntu.com/ubuntu noble-security/main amd64 openssl amd64 3.0.13-0ubuntu3.5 [1,005 kB]",
                             "Fetched 1,005 kB in 1s (1,100 kB/s)", "Preparing to unpack .../openssl_3.0.13-0ubuntu3.5_amd64.deb ...",
                             "Unpacking openssl (3.0.13-0ubuntu3.5) over (3.0.13-0ubuntu3.4) ...",
                             "Setting up openssl (3.0.13-0ubuntu3.5) ...", "(demo: nothing was installed)"]
                for line in lines {
                    try? await Task.sleep(for: .milliseconds(450))
                    if Task.isCancelled { break }
                    continuation.yield(line + "\r\n")
                }
                continuation.yield("\r\n##rackoon-exit:0\r\n")
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
