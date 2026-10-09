import AppKit
import HomebaseCore
import HomebaseSSHSystem
import Foundation
import Observation
import SwiftTerm

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

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
        view.startProcess(
            executable: "/usr/bin/ssh",
            args: OpenSSHTransport.terminalArguments(for: server),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
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

    /// All bundled themes, and the one used by every terminal (one theme for all servers).
    let themes: [TerminalTheme]
    /// Set when themes.json could not be loaded; the drawer shows it and a plain fallback theme is used.
    let themeError: String?
    private(set) var theme: TerminalTheme

    private static let themeKey = "terminalThemeID"

    init() {
        var loaded: [TerminalTheme] = []
        var loadError: String?
        do {
            guard let url = Bundle.module.url(forResource: "themes", withExtension: "json") else {
                throw ThemeCatalogError.invalid("themes.json is missing from the app bundle")
            }
            loaded = try ThemeCatalog.load(from: Data(contentsOf: url))
        } catch {
            loadError = error.localizedDescription
        }
        let fallback = TerminalTheme(
            id: ThemeCatalog.defaultID, name: "Default", family: "Homebase", appearance: "dark",
            background: "#000000", foreground: "#E5E5E5",
            ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
                   "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#FFFFFF"])
        themes = loaded.isEmpty ? [fallback] : loaded
        themeError = loadError
        let saved = UserDefaults.standard.string(forKey: Self.themeKey)
        theme = themes.first { $0.id == saved } ?? themes.first { $0.id == ThemeCatalog.defaultID } ?? themes[0]
    }

    /// Applies to every open tab now, to new tabs when they are created, and is remembered for next launch.
    func select(theme: TerminalTheme) {
        guard theme.id != self.theme.id else { return }
        self.theme = theme
        UserDefaults.standard.set(theme.id, forKey: Self.themeKey)
        for list in tabs.values { for tab in list { tab.apply(theme) } }
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
        let tab = TerminalTab(server: server, title: "Shell \(n)", theme: theme)
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
