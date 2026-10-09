import AppKit
import HomebaseCore
import HomebaseSSHSystem
import Observation
import SwiftTerm

/// One terminal tab: an ssh process on a PTY, rendered by SwiftTerm. The view is owned here, not by
/// SwiftUI, so the session survives switching screens, tabs and servers.
@MainActor @Observable
final class TerminalTab: Identifiable {
    nonisolated let id = UUID()
    var title: String
    private(set) var isRunning = true
    private(set) var exitCode: Int32?
    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private let server: Server
    @ObservationIgnored private var proxy: DelegateProxy?

    static let scrollbackLines = 10_000

    init(server: Server, title: String) {
        self.server = server
        self.title = title
        view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.changeScrollback(Self.scrollbackLines)
        let proxy = DelegateProxy(tab: self)
        self.proxy = proxy
        view.processDelegate = proxy
        launch()
    }

    private func launch() {
        isRunning = true
        exitCode = nil
        view.startProcess(
            executable: "/usr/bin/ssh",
            args: OpenSSHTransport.terminalArguments(for: server),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
    }

    func reconnect() {
        guard !isRunning else { return }
        view.resetToInitialState()
        launch()
    }

    func close() {
        if isRunning { view.terminate() }
        isRunning = false
    }

    fileprivate func ended(exitCode: Int32?) {
        isRunning = false
        self.exitCode = exitCode
    }

    /// SwiftTerm calls these off the main actor; forward what we need.
    private final class DelegateProxy: NSObject, LocalProcessTerminalViewDelegate {
        weak var tab: TerminalTab?
        init(tab: TerminalTab) { self.tab = tab }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in self.tab?.ended(exitCode: exitCode) }
        }
        func processFailedToStart(source: TerminalView, error: LocalProcessError) {
            Task { @MainActor in self.tab?.ended(exitCode: nil) }
        }
        func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {}
    }
}

/// Tabs per server. A server's first tab is created when its Terminal screen is first opened.
@MainActor @Observable
final class TerminalStore {
    private(set) var tabs: [String: [TerminalTab]] = [:]
    private(set) var selected: [String: UUID] = [:]
    @ObservationIgnored private var counters: [String: Int] = [:]

    func tabs(for server: Server) -> [TerminalTab] { tabs[server.id] ?? [] }

    func selectedTab(for server: Server) -> TerminalTab? {
        let list = tabs(for: server)
        return list.first { $0.id == selected[server.id] } ?? list.first
    }

    /// Opens the first tab if the server has none yet.
    func ensureTab(for server: Server) {
        if tabs(for: server).isEmpty { newTab(for: server) }
    }

    func newTab(for server: Server) {
        let n = (counters[server.id] ?? 0) + 1
        counters[server.id] = n
        let tab = TerminalTab(server: server, title: "Shell \(n)")
        tabs[server.id, default: []].append(tab)
        selected[server.id] = tab.id
    }

    func select(_ tab: TerminalTab, for server: Server) { selected[server.id] = tab.id }

    func close(_ tab: TerminalTab, for server: Server) {
        guard var list = tabs[server.id], let i = list.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.close()
        list.remove(at: i)
        tabs[server.id] = list
        if selected[server.id] == tab.id { selected[server.id] = list.indices.contains(i) ? list[i].id : list.last?.id }
    }

    func closeAll(for server: Server) {
        tabs[server.id]?.forEach { $0.close() }
        tabs[server.id] = nil
        selected[server.id] = nil
        counters[server.id] = nil
    }
}
