import Foundation
import HomebaseCore
import HomebaseSSHSystem
import Observation

/// Bridges DockerSession and the log stream to SwiftUI. Lives only while the Docker screen is open,
/// so `docker stats` is not polled in the background.
@MainActor @Observable
final class DockerModel {
    private(set) var state = DockerState()
    private(set) var logs = LogBuffer()
    private(set) var logTarget: DockerContainer?
    private(set) var logsLive = false
    private(set) var logError: String?

    @ObservationIgnored private let session: DockerSession
    @ObservationIgnored private let transport: SSHTransport
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?

    init(server: Server) {
        let transport = OpenSSHTransport(server: server)
        self.transport = transport
        session = DockerSession(transport: transport)
    }

    func start() {
        guard listener == nil else { return }
        let session = session
        listener = Task { [weak self] in
            for await next in await session.updates() { self?.state = next }
        }
        Task { await session.start() }
    }

    func stop() {
        closeLogs()
        listener?.cancel(); listener = nil
        let session = session
        Task { await session.stop() }
    }

    func refresh() {
        let session = session
        Task { await session.refresh() }
    }

    func perform(_ action: DockerAction, on container: DockerContainer) {
        let session = session
        Task { await session.perform(action, containerID: container.id) }
    }

    func showLogs(for container: DockerContainer) {
        guard logTarget?.id != container.id else { return }
        closeLogs()
        guard let command = DockerSession.logsCommand(id: container.id) else { return }
        logTarget = container
        logs = LogBuffer()
        logError = nil
        logsLive = true
        let transport = transport
        logTask = Task { [weak self] in
            do {
                for try await chunk in transport.stream(command) {
                    self?.logs.append(chunk)
                }
            } catch {
                self?.logError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            self?.logsLive = false
        }
    }

    func closeLogs() {
        logTask?.cancel(); logTask = nil   // cancelling sends Ctrl-C to the remote `docker logs -f`
        logTarget = nil
        logsLive = false
    }
}
