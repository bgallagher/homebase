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

/// Canned answers for a fake reboot: the boot id changes about 12 seconds after the reboot command, and the
/// server "does not answer" in between. Never talks to a server.
private final class DemoRebootTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var rebootedAt: Date?

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult { answer(command) }

    private func answer(_ command: String) -> CommandResult {
        lock.withLock {
            if command == RebootSession.rebootCommand {
                rebootedAt = Date()
                return CommandResult(stdout: "##rebooting\n")
            }
            guard let at = rebootedAt else { return CommandResult(stdout: "demo-boot-1\n") }
            let age = Date().timeIntervalSince(at)
            if age < 4 { return CommandResult(stdout: "demo-boot-1\n") }          // still the old system
            if age < 12 { return CommandResult(stdout: "", stderr: "ssh: connect to host: Connection refused", exitCode: 255) }
            return CommandResult(stdout: "demo-boot-2\n")
        }
    }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

/// A reboot in progress for one server: asks the server to reboot, then waits until it answers with a new boot id.
@MainActor @Observable
final class RebootFlow {
    enum Phase: Equatable {
        case requesting
        case waiting(since: Date)
        case back(after: TimeInterval)
        case timedOut
        case failed(String)
    }

    private(set) var phase: Phase = .requesting
    var isActive: Bool {
        switch phase { case .requesting, .waiting: true; default: false }
    }
    @ObservationIgnored private let session: RebootSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onBack: () -> Void = {}

    init(server: Server) {
        // RACKOON_DEMO_REBOOT=1 swift run RackoonMac: pretend to reboot (nothing is sent to the server) and come back
        // after about 15 seconds, so the waiting banner can be seen without taking a real server down.
        let transport: SSHTransport = ProcessInfo.processInfo.environment["RACKOON_DEMO_REBOOT"] != nil || Demo.isOn
            ? DemoRebootTransport() : makeTransport(for: server)
        session = RebootSession(transport: transport, policy: SafetyStore.shared.policy)
    }

    func start() {
        task = Task {
            do {
                try await session.reboot(confirmation: try session.confirm())
                phase = .waiting(since: Date())
                switch await session.waitForReturn() {
                case .back(let elapsed):
                    phase = .back(after: elapsed)
                    onBack()
                case .timedOut:
                    phase = .timedOut
                }
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// Saved servers, the selected server, and the live session for it.
/// Only the selected server is polled, so we hold one SSH connection at a time.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [Server]
    private(set) var selectedID: String?
    private(set) var phase: ConnectionPhase = .idle
    private(set) var state = ServerState()
    /// Reboots started from this app, by server id (kept after they finish so the result can be read and dismissed).
    private(set) var reboots: [String: RebootFlow] = [:]
    /// A reboot waiting for the user's yes (shown as a sheet by the Overview screen).
    var pending: PendingAction?

    private let store: ServerStore
    private let verifier = HostKeyVerifier()
    private var session: ServerSession?
    private var listener: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    var selected: Server? { servers.first { $0.id == selectedID } }

    init(store: ServerStore = Demo.isOn ? Demo.store() : .defaultStore()) {
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
        if !Demo.isOn { UserDefaults.standard.set(server.id, forKey: "selectedServerID") }
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

    func requestReboot(_ server: Server) {
        guard !SafetyStore.shared.readOnly, reboots[server.id]?.isActive != true else { return }
        pending = PendingAction(
            title: "Reboot \(server.name)?",
            message: "The server restarts in a couple of seconds. Everything running on it stops and comes back with it. Rackoon waits and reconnects when it is up again.",
            serverName: server.name, command: RebootSession.rebootCommand, destructive: true,
            run: { [weak self] in
                guard let self else { return }
                let flow = RebootFlow(server: server)
                flow.onBack = { [weak self] in self?.refresh() }   // poll straight away instead of waiting for the next tick
                self.reboots[server.id] = flow
                flow.start()
            })
    }

    func dismissReboot(_ server: Server) {
        reboots[server.id]?.cancel()
        reboots[server.id] = nil
    }

    /// True while a manual refresh is running (the Overview's Refresh button shows it).
    private(set) var refreshing = false

    func refresh() {
        guard let session, !refreshing else { return }
        refreshing = true
        Task {
            await session.refresh()
            try? await Task.sleep(for: .milliseconds(500))   // long enough to be seen when the answer is instant
            refreshing = false
        }
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
            let status: HostKeyStatus = Demo.isOn ? .trusted : await verifier.check(server)
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
            transport: makeTransport(for: server),
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
