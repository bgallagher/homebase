import AppKit
import RackoonCore
import RackoonSSHSystem
import Observation

enum ConnectionPhase: Equatable {
    case idle
    case checkingHostKey
    case needsTrust(HostKeyOffer)
    /// Host key changed: connecting is blocked until the user fixes known_hosts themselves.
    case blocked(String)
    case polling
}

/// Saved servers, the selected server, and the live session for it.
/// Only the selected server is polled, so we hold one SSH connection at a time.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [Server]
    private(set) var selectedID: String?
    private(set) var phase: ConnectionPhase = .idle
    private(set) var state = ServerState()

    private let store: ServerStore
    private let verifier = HostKeyVerifier()
    private var session: ServerSession?
    private var listener: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    var selected: Server? { servers.first { $0.id == selectedID } }

    init(store: ServerStore = .defaultStore()) {
        self.store = store
        servers = store.loadServers()
        let last = UserDefaults.standard.string(forKey: "selectedServerID")
        selectedID = servers.contains { $0.id == last } ? last : servers.first?.id
    }

    func start() {
        // Registered here, not in init: `@State private var model = AppModel()` runs init on every parent
        // re-evaluation and discards all but the first instance, which would leak an observer each time.
        if wakeObserver == nil {
            // After sleep the SSH connection is usually dead: poll straight away instead of waiting for the next tick.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        if let selected { connect(selected) }
    }

    func select(_ server: Server) {
        guard server.id != selectedID else { return }
        selectedID = server.id
        UserDefaults.standard.set(server.id, forKey: "selectedServerID")
        connect(server)
    }

    func add(_ server: Server) {
        servers.append(server)
        persist()
        select(server)
        if selectedID == server.id, phase == .idle { connect(server) }
    }

    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        store.deleteSnapshot(serverID: server.id)
        persist()
        if selectedID == server.id {
            disconnect()
            selectedID = servers.first?.id
            state = ServerState()
            phase = .idle
            if let next = selected { connect(next) }
        }
    }

    func refresh() {
        if let session { Task { await session.refresh() } }
    }

    /// The user confirmed the fingerprint shown in the trust sheet.
    func trustPending() {
        guard case .needsTrust(let offer) = phase, let server = selected else { return }
        do {
            try verifier.trust(offer)
            connect(server)
        } catch {
            state.error = "Could not save the host key: \(error.localizedDescription)"
            phase = .idle
        }
    }

    func declineTrust() {
        guard case .needsTrust = phase else { return }
        state.error = "Not connected: the host key was not trusted."
        phase = .idle
    }

    // MARK: - Connecting

    private func connect(_ server: Server) {
        disconnect()
        // Paint the last known data straight away, marked stale until the first poll lands.
        state = ServerState()
        if let cached = store.loadSnapshot(serverID: server.id) {
            state.overview = cached.overview
            state.attention = Attention.evaluate(cached.overview)
            state.updatedAt = cached.savedAt
            state.isStale = true
        }
        phase = .checkingHostKey
        connecting = Task { [weak self] in
            guard let self else { return }
            let status = await verifier.check(server)
            if Task.isCancelled { return }
            switch status {
            case .trusted:
                startSession(for: server)
            case .failed(let message):
                // Unreachable right now: keep polling so it recovers when the network returns.
                state.error = message
                startSession(for: server)
            case .unknown(let offer):
                phase = .needsTrust(offer)
            case .changed(let message):
                state.error = message
                phase = .blocked(message)
            }
        }
    }

    private func startSession(for server: Server) {
        let store = store, id = server.id
        let cached = state.overview.flatMap { o in state.updatedAt.map { (overview: o, savedAt: $0) } }
        let session = ServerSession(
            transport: OpenSSHTransport(server: server),
            cached: cached,
            onSnapshot: { overview in try? store.saveSnapshot(overview, serverID: id) })
        self.session = session
        phase = .polling
        listener = Task { [weak self] in
            for await next in await session.updates() { self?.state = next }
        }
        Task { await session.start() }
    }

    private func disconnect() {
        connecting?.cancel(); connecting = nil
        listener?.cancel(); listener = nil
        if let session { Task { await session.stop() } }
        session = nil
    }

    private func persist() {
        try? store.saveServers(servers)
    }
}
