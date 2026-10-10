import AppKit
import RackoonCore
import RackoonSSHSystem
import Foundation
import Observation
import SwiftTerm

/// One terminal tab: an ssh process on a PTY, rendered by SwiftTerm. The view is owned here, not by
/// SwiftUI, so the session survives switching screens, tabs and servers.
@MainActor @Observable
final class TerminalTab: Identifiable {
    nonisolated let id = UUID()
    var title: String
    /// What the tab was called when it opened ("Shell 2", "Shell · web"), restored when a rename is left empty.
    @ObservationIgnored let defaultTitle: String
    private(set) var isRunning = true
    private(set) var exitCode: Int32?
    /// While an automatic reconnect is pending or under way: which attempt (1-based) and when it starts.
    private(set) var reconnecting: (attempt: Int, of: Int, at: Date)?
    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private let server: Server
    /// Run instead of a login shell (e.g. `docker exec` for a container shell); nil for a normal shell.
    @ObservationIgnored private let remoteCommand: String?
    @ObservationIgnored private var proxy: DelegateProxy?

    static let scrollbackLines = 10_000

    /// Where the output-highlighting relay lives, next to the app's own executable (`swift run`, and later
    /// Contents/MacOS in the app bundle). Nil if it is missing, in which case terminals run ssh directly.
    static var relayURL: URL? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent("rackoon-pty")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// True when this tab's ssh was started through the relay, which is what lets highlighting be switched live.
    @ObservationIgnored private var viaRelay = false
    /// Bumped on every launch, so a delayed signal meant for an earlier session can never reach a newer relay.
    @ObservationIgnored private var launchGeneration = 0
    @ObservationIgnored private var launchedAt = Date()
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    /// ssh exits 255 when the connection itself fails or drops; anything else is the remote command's own status
    /// (including 0 when the user typed `exit`), which must never be retried.
    static let connectionLostExit: Int32 = 255
    static let maxAutoAttempts = 5
    /// A session that lasted at least this long counts as having worked, so the retry budget starts over.
    static let healthyAfter: TimeInterval = 10
    static func backoff(attempt: Int) -> TimeInterval { min(pow(2, Double(attempt - 1)), 15) }   // 1, 2, 4, 8, 15 s

    init(server: Server, title: String, theme: TerminalTheme, remoteCommand: String? = nil) {
        self.server = server
        self.remoteCommand = remoteCommand
        self.title = title
        defaultTitle = title
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
        launchedAt = Date()
        let ssh = OpenSSHTransport.terminalArguments(for: server) + (remoteCommand.map { [$0] } ?? [])
        let environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        launchGeneration += 1
        if Demo.isOn {
            // Demo mode: a scripted fake shell that never runs what is typed (see Demo.swift). Through the relay when it exists,
            // so output highlighting looks as it does on a real server.
            let shell = ["/bin/bash", Demo.terminalScript().path, server.name]
            viaRelay = Self.relayURL != nil
            if let relay = Self.relayURL {
                let flags = AppearanceStore.shared.highlightOutput ? [] : ["--no-highlight"]
                view.startProcess(executable: relay.path, args: flags + ["--"] + shell, environment: environment)
            } else {
                view.startProcess(executable: shell[0], args: Array(shell.dropFirst()), environment: environment)
            }
            return
        }
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
    ///
    /// Those signals terminate a process that has not installed handlers yet, so a relay is only signalled once
    /// it has published its ready marker (written after its handlers are installed). A relay that is still
    /// starting is retried briefly; the value sent is always the setting as it is at that moment.
    func setHighlight() {
        guard viaRelay, isRunning else { return }
        let generation = launchGeneration
        Task { [weak self] in
            for _ in 0..<50 {   // up to ~5 s for a relay that is still starting
                guard let self, self.launchGeneration == generation, self.isRunning else { return }
                let pid = self.view.process.shellPid
                if pid > 0, FileManager.default.fileExists(atPath: Self.readyMarker(pid: pid)) {
                    kill(pid, AppearanceStore.shared.highlightOutput ? SIGUSR1 : SIGUSR2)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func readyMarker(pid: pid_t) -> String { "/tmp/rk-\(getuid())/relay-\(pid).ready" }

    func apply(_ theme: TerminalTheme) { view.applyRackoonTheme(theme) }

    /// Names the tab so several can be told apart. Blank text puts the original name back; very long names are cut.
    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmed.isEmpty ? defaultTitle : String(trimmed.prefix(40))
    }

    /// Puts the keyboard back in the terminal (after typing a name).
    func focusTerminal() { view.window?.makeFirstResponder(view) }

    /// Manual reconnect (the button): starts a fresh screen and a fresh retry budget.
    func reconnect() {
        guard !isRunning else { return }
        cancelAutoReconnect()
        failedAttempts = 0
        view.resetToInitialState()
        launch()
    }

    /// Stops waiting for the next automatic attempt and leaves the tab ended with the Reconnect button.
    func cancelAutoReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = nil
    }

    func close() {
        cancelAutoReconnect()
        if isRunning { view.terminate() }
        isRunning = false
    }

    fileprivate func ended(exitCode: Int32?) {
        isRunning = false
        self.exitCode = exitCode
        guard exitCode == Self.connectionLostExit else { failedAttempts = 0; return }
        if Date().timeIntervalSince(launchedAt) >= Self.healthyAfter { failedAttempts = 0 }
        guard failedAttempts < Self.maxAutoAttempts else { return }
        failedAttempts += 1
        scheduleReconnect(attempt: failedAttempts)
    }

    private func scheduleReconnect(attempt: Int) {
        let delay = Self.backoff(attempt: attempt)
        reconnecting = (attempt, Self.maxAutoAttempts, Date().addingTimeInterval(delay))
        view.feed(text: "\r\n\u{1B}[2m[connection lost, reconnecting in \(Int(delay)) s]\u{1B}[0m\r\n")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.reconnecting = nil
            self.launch()
        }
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

    private var allTabs: [TerminalTab] { tabs.values.flatMap { $0 } }

    /// The Highlight output setting changed: tell every open relay.
    func highlightSettingChanged() {
        allTabs.forEach { $0.setHighlight() }
    }

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

    /// A tab that runs `command` on the server instead of a login shell, titled `title` (e.g. "Shell · web").
    func newTab(for server: Server, title: String? = nil, command: String? = nil) {
        let n = (counters[server.id] ?? 0) + 1
        counters[server.id] = n
        let tab = TerminalTab(server: server, title: title ?? "Shell \(n)", theme: AppearanceStore.shared.resolvedTheme,
                              remoteCommand: command)
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

extension TerminalView {
    /// Sets the ANSI palette first, then the default colours (installing a palette can reset them).
    func applyRackoonTheme(_ theme: TerminalTheme) {
        installColors(theme.ansiRGB.map { Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        nativeBackgroundColor = theme.backgroundRGB.nsColor
        nativeForegroundColor = theme.foregroundRGB.nsColor
        caretColor = theme.cursorRGB.nsColor
        // A theme's own selection colour is used as is; without one, a translucent foreground stays readable.
        selectedTextBackgroundColor = theme.selection == nil
            ? theme.foregroundRGB.nsColor.withAlphaComponent(0.3) : theme.selectionRGB.nsColor
    }
}
