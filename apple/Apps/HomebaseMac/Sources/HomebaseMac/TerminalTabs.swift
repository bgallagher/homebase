import AppKit
import HomebaseCore
import HomebaseSSHSystem
import Foundation
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

    /// Where the output-highlighting relay lives, next to the app's own executable (`swift run`, and later
    /// Contents/MacOS in the app bundle). Nil if it is missing, in which case terminals run ssh directly.
    static var relayURL: URL? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent("homebase-pty")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// True when this tab's ssh was started through the relay, which is what lets highlighting be switched live.
    @ObservationIgnored private var viaRelay = false
    @ObservationIgnored private var launchedAt = Date()

    init(server: Server, title: String, theme: TerminalTheme) {
        self.server = server
        self.title = title
        view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.changeScrollback(Self.scrollbackLines)
        apply(theme)
        let proxy = DelegateProxy(tab: self)
        self.proxy = proxy
        view.processDelegate = proxy
        launch()
    }

    private func launch() {
        isRunning = true
        exitCode = nil
        let ssh = OpenSSHTransport.terminalArguments(for: server)
        let environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        launchedAt = Date()
        if let relay = Self.relayURL {
            // Always go through the relay when it exists, even with highlighting off, so the switch can be
            // flipped later on this very tab.
            viaRelay = true
            let flags = AppearanceStore.shared.highlightOutput ? [] : ["--no-highlight"]
            view.startProcess(executable: relay.path, args: flags + ["--", "/usr/bin/ssh"] + ssh, environment: environment)
        } else {
            viaRelay = false
            view.startProcess(executable: "/usr/bin/ssh", args: ssh, environment: environment)
        }
    }

    /// Tells the running relay to switch highlighting on (SIGUSR1) or off (SIGUSR2). Both are idempotent.
    /// The relay installs its handlers right after it starts; signalling before that would kill it (the default
    /// action for these signals), so a brand-new tab is given a moment, then gets whatever the setting is by then.
    func setHighlight(_ on: Bool) {
        guard viaRelay, isRunning else { return }
        let settle = 0.6 - Date().timeIntervalSince(launchedAt)
        if settle > 0 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                guard let self else { return }
                self.sendHighlight(AppearanceStore.shared.highlightOutput)
            }
        } else {
            sendHighlight(on)
        }
    }

    private func sendHighlight(_ on: Bool) {
        guard viaRelay, isRunning else { return }
        let pid = view.process.shellPid
        if pid > 0 { kill(pid, on ? SIGUSR1 : SIGUSR2) }
    }

    /// Sets the ANSI palette first, then the default colours (installing a palette can reset them).
    func apply(_ theme: TerminalTheme) {
        view.installColors(theme.ansiRGB.map { Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        view.nativeBackgroundColor = theme.backgroundRGB.nsColor
        view.nativeForegroundColor = theme.foregroundRGB.nsColor
        view.caretColor = theme.cursorRGB.nsColor
        // A theme's own selection colour is used as is; without one, a translucent foreground stays readable.
        view.selectedTextBackgroundColor = theme.selection == nil
            ? theme.foregroundRGB.nsColor.withAlphaComponent(0.3) : theme.selectionRGB.nsColor
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

    init() {
        // The appearance switch lives in AppearanceStore; open terminals are told about changes here.
        AppearanceStore.shared.onHighlightChange = { [weak self] on in
            self?.allTabs.forEach { $0.setHighlight(on) }
        }
    }

    private var allTabs: [TerminalTab] { tabs.values.flatMap { $0 } }

    /// The theme changed (or macOS switched appearance under Automatic): recolour every open terminal.
    func applyTheme(_ theme: TerminalTheme) {
        allTabs.forEach { $0.apply(theme) }
    }

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
        let tab = TerminalTab(server: server, title: "Shell \(n)", theme: AppearanceStore.shared.resolvedTheme)
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
