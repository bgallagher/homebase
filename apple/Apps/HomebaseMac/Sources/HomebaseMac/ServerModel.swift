import HomebaseCore
import HomebaseSSHSystem
import Observation

/// Bridges a ServerSession actor to SwiftUI. Views read `state`; they never touch SSH.
@MainActor @Observable
final class ServerModel {
    private(set) var state = ServerState()
    private var session: ServerSession?
    private var listener: Task<Void, Never>?

    func connect(host: String) {
        disconnect()
        state = ServerState()
        guard !host.isEmpty else { return }
        let session = ServerSession(transport: OpenSSHTransport(host: host))
        self.session = session
        listener = Task { [weak self] in
            for await next in await session.updates() {
                self?.state = next
            }
        }
        Task { await session.start() }
    }

    func disconnect() {
        listener?.cancel()
        listener = nil
        if let session { Task { await session.stop() } }
        session = nil
    }

    func refresh() {
        if let session { Task { await session.refresh() } }
    }
}
