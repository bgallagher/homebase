import Foundation
import Observation
import RackoonCore
import RackoonSSHSystem

/// Docker through sudo, for servers where the ssh user may not use Docker directly. Nothing on the server changes: once
/// the user unlocks it (the sudo password, or a saved one after Touch ID / Apple Watch / login password), every Docker
/// command for that server runs as `sudo … sh -c '<command>'` (`SudoTransport`) until the window ends or the user
/// locks it. The password is held in memory only for that window, never written anywhere.
@MainActor @Observable
final class DockerElevation {
    static let shared = DockerElevation()
    /// Like sudo's own default grace period.
    static let window: TimeInterval = ElevationWindow.defaultLength

    /// The rules (who is unlocked, until when, why locked) live in Core's `ElevationWindow`, which is tested.
    private var state = ElevationWindow(length: DockerElevation.window)
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]

    var lockReason: [String: String] { state.lockReasons }

    func isUnlocked(_ server: Server) -> Bool { state.active(server.id, at: Date()) != nil }
    func unlockedUntil(_ server: Server) -> Date? { state.active(server.id, at: Date())?.until }
    func key(_ server: Server) -> String { "\(server.connectionKey)|\(state.generation(server.id))" }

    /// The transport for anything Docker on this server: through sudo while unlocked, plain otherwise.
    func transport(for server: Server) -> SSHTransport {
        let base = makeTransport(for: server)
        guard !Demo.isOn, let unlock = state.active(server.id, at: Date()) else { return base }
        let id = server.id
        return SudoTransport(base: base, password: unlock.password, validUntil: unlock.until, onRejected: {
            Task { @MainActor in DockerElevation.shared.lock(id, reason: SudoTransportError.rejected.errorDescription) }
        })
    }

    func unlock(_ server: Server, password: String) {
        state.unlock(server.id, password: password, now: Date())
        let id = server.id
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.window))
            guard !Task.isCancelled else { return }
            self?.lock(id, reason: "Docker access through sudo ended after \(Int(Self.window / 60)) minutes. Unlock it again to continue.")
        }
    }

    func lock(_ serverID: String, reason: String? = nil) {
        timers[serverID]?.cancel()
        timers[serverID] = nil
        state.lock(serverID, reason: reason)
    }

    /// Checks the password with a harmless `sudo -S -v` on its own connection before unlocking. nil when accepted,
    /// otherwise why not.
    static func check(_ password: String, on server: Server) async -> String? {
        let transport = OpenSSHTransport(server: server)
        guard let result = try? await transport.run("sudo -S -p '' -v", input: password + "\n", timeout: 20) else {
            return "Could not reach the server to check the password."
        }
        if result.exitCode == 0 { return nil }
        let said = result.stdout + "\n" + result.stderr
        return SudoElevation.isAuthFailure(said) ? "The server did not accept that password." : SudoElevation.explainRefusal(said)
    }
}

/// Where Docker-related models get their connection.
@MainActor func dockerTransport(for server: Server) -> SSHTransport { DockerElevation.shared.transport(for: server) }

import SwiftUI

/// Docker's access notice, for the Docker and Bookmarks screens: when the ssh user may not use Docker, offer to unlock it
/// with the sudo password; while unlocked, say until when and offer Lock. Any other Docker error is a plain error banner.
struct DockerAccessNotice: View {
    let server: Server
    let error: String?
    @State private var request: SudoRequest?
    @State private var working = false
    private let elevation = DockerElevation.shared

    var body: some View {
        Group {
            if let until = elevation.unlockedUntil(server) {
                NoticeRow(icon: "lock.open.fill", tint: Theme.accent,
                          message: "Docker is running through sudo until \(until.formatted(date: .omitted, time: .shortened)).",
                          detail: "Nothing on the server was changed. The password is kept in memory only until then.",
                          action: AttentionAction(title: "Lock", help: "Stop using sudo for Docker now", run: { elevation.lock(server.id) }))
                    .noticeSurface(.info)
            } else if let error, DockerAccess.isPermissionProblem(error) {
                NoticeRow(icon: "lock.fill", tint: Theme.warn,
                          message: "\(server.user ?? "This user") can't use Docker on \(server.name) without sudo.",
                          detail: elevation.lockReason[server.id]
                            ?? "Unlock to run Docker commands through sudo for \(Int(DockerElevation.window / 60)) minutes. Nothing on the server is changed.",
                          action: AttentionAction(title: working ? "Unlocking…" : "Unlock with sudo…", enabled: !working, run: start))
                    .noticeSurface(.warn)
            } else if let error {
                ErrorBanner(message: error)
            }
        }
        .sudoPassword($request)
    }

    /// A saved password: Touch ID / Apple Watch / login password. Otherwise the password sheet.
    private func start() {
        let server = server
        guard SudoVault.shared.isRemembered(server) else { ask(problem: nil); return }
        working = true
        Task {
            defer { working = false }
            switch await SudoVault.shared.unlock(server, reason: SudoVault.reason(server, doing: "use Docker")) {
            case .success(let password):
                if let problem = await DockerElevation.check(password, on: server) {
                    if problem == "The server did not accept that password." { SudoVault.shared.forget(server.id) }
                    ask(problem: problem == "The server did not accept that password." ? "The saved sudo password was not accepted, so it was forgotten." : problem)
                } else {
                    elevation.unlock(server, password: password)
                }
            case .failure(.cancelled):
                break
            case .failure(let error):
                ask(problem: error.sheetProblem)
            }
        }
    }

    private func ask(problem: String?) {
        let server = server
        request = SudoRequest(
            title: "Use Docker on \(server.name) with sudo", server: server,
            command: "sudo -S -p '' sh -c '<each Docker command>'",
            problem: problem, actionLabel: "Unlock", canRemember: SudoVault.shared.canRemember,
            submit: { password, remember in
                working = true
                Task {
                    defer { working = false }
                    if let problem = await DockerElevation.check(password, on: server) {
                        ask(problem: problem)
                        return
                    }
                    elevation.unlock(server, password: password)
                    if remember { await SudoVault.shared.remember(password, for: server) }
                }
            })
    }
}
