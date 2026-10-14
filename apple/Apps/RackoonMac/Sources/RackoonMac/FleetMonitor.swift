import AppKit
import Observation
import RackoonCore
import RackoonSSHSystem

/// The last reading of a server that is not on screen, for its status light in the sidebar.
struct FleetEntry: Equatable {
    var state = ServerState()
    /// Set when the server is not polled: its host key is not trusted yet, or it changed.
    var blocked: String?
    /// The host key has never been trusted: grey, not red, because nothing is wrong yet.
    var untrusted = false

    var status: ConnectionStatus {
        if untrusted { return .none }
        if blocked != nil || state.error != nil { return .failing }
        return state.overview == nil || state.isStale ? .connecting : .connected
    }

    /// The status light's tooltip.
    var summary: String {
        if let blocked { return blocked }
        if let error = state.error { return "Not answering: \(error)" }
        guard state.overview != nil, !state.isStale, let at = state.updatedAt else { return "Checking…" }
        return "Online, checked \(at.formatted(date: .omitted, time: .shortened)) (every minute while not selected)"
    }
}

/// Keeps a slow poll (once a minute) running for every saved server except the selected one, which `AppModel` polls
/// every few seconds. Each server's host key is checked once before its first poll, the same way the selected server's
/// is; an unknown or changed key is never polled (it shows red, and selecting the server offers the usual trust sheet).
/// Polls reuse the ssh ControlMaster connection, which stays open for two minutes, so a poll is one remote command.
@MainActor @Observable
final class FleetMonitor {
    static let interval: TimeInterval = 60

    private(set) var entries: [String: FleetEntry] = [:]
    /// The last hour of checks of every server, selected or not (the dashboard's heartbeat bars and sparklines). In memory only.
    private(set) var histories: [String: HealthHistory] = [:]

    @ObservationIgnored private let store: ServerStore
    @ObservationIgnored private let verifier = HostKeyVerifier()
    @ObservationIgnored private var sessions: [String: ServerSession] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Servers whose host key was found trusted during this run, by this monitor or by `AppModel`.
    @ObservationIgnored private var trusted: Set<String> = []

    init(store: ServerStore) {
        self.store = store
    }

    /// The host key of `id` was checked and trusted elsewhere (the selected server's connect), so no second check is needed.
    func noteTrusted(_ id: String) { trusted.insert(id) }

    /// Polls exactly `servers` minus `selectedID`. Starting a server paints its cached snapshot first (grey until a poll lands).
    func sync(servers: [Server], selectedID: String?) {
        let wanted = Dictionary(servers.filter { $0.id != selectedID }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in Array(tasks.keys) where wanted[id] == nil { stop(id) }
        for id in Array(entries.keys) where !servers.contains(where: { $0.id == id }) { entries[id] = nil }
        for id in Array(histories.keys) where !servers.contains(where: { $0.id == id }) { histories[id] = nil }
        for (id, server) in wanted where tasks[id] == nil { start(server) }
    }

    /// Forgets everything about `id` (its connection details changed), so the next `sync` starts from the host-key check.
    func reset(_ id: String) {
        stop(id)
        trusted.remove(id)
        entries[id] = nil
        histories[id] = nil
    }

    /// Adds a poll's result to the server's history (the selected server's polls come from `AppModel`).
    func record(_ id: String, _ state: ServerState) {
        guard let sample = HealthSample(state: state, at: Date()) else { return }
        histories[id, default: HealthHistory()].record(sample)
    }

    /// Hands over a server that stops being selected: its fresh reading is shown at once instead of the cached one.
    func seed(_ id: String, with state: ServerState) {
        guard state.overview != nil || state.error != nil else { return }
        entries[id] = FleetEntry(state: state)
    }

    /// Poll every background server now (after the Mac wakes, when every connection is likely dead).
    func refreshAll() {
        for session in sessions.values { Task { await session.refresh() } }
    }

    // MARK: -

    private func start(_ server: Server) {
        let id = server.id
        entries[id]?.blocked = nil   // checked again below
        entries[id]?.untrusted = false
        if entries[id] == nil, let cached = store.loadSnapshot(serverID: id) {
            var state = ServerState()
            state.overview = cached.overview
            state.attention = Attention.evaluate(cached.overview)
            state.updatedAt = cached.savedAt
            state.isStale = true
            entries[id] = FleetEntry(state: state)
        }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            if !Demo.isOn, !trusted.contains(id) {
                switch await verifier.check(server) {
                case .trusted, .authFailed, .failed:
                    // Login refused or unreachable right now: the key itself is fine, so keep polling until it recovers.
                    trusted.insert(id)
                case .unknown:
                    block(id, "Not connected yet: select the server to check and trust its host key.", untrusted: true)
                    return
                case .changed(let message):
                    block(id, message)
                    return
                }
            }
            if Task.isCancelled { return }
            await poll(server)
        }
    }

    private func poll(_ server: Server) async {
        let id = server.id, store = store
        let cached = entries[id].flatMap { e in e.state.overview.flatMap { o in e.state.updatedAt.map { (overview: o, savedAt: $0) } } }
        let session = ServerSession(transport: makeTransport(for: server), interval: Self.interval, cached: cached,
                                    onSnapshot: { overview in try? store.saveSnapshot(overview, serverID: id) })
        sessions[id] = session
        await session.start()
        for await next in await session.updates() {
            if Task.isCancelled { break }
            entries[id] = FleetEntry(state: next)
            record(id, next)
        }
    }

    private func block(_ id: String, _ reason: String, untrusted: Bool = false) {
        var entry = entries[id] ?? FleetEntry()
        entry.blocked = reason
        entry.untrusted = untrusted
        entries[id] = entry
    }

    private func stop(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let session = sessions.removeValue(forKey: id) { Task { await session.stop() } }
    }
}
