import AppKit
import RackoonCore
import SwiftTerm
import SwiftUI

/// A read-only terminal showing a streamed run. It is a real terminal emulator, so compose's own progress (the lines
/// that redraw as containers stop and start) looks exactly as it does in a terminal. Use `.id(run.id)` so a new run
/// gets a fresh screen.
struct OutputTerminalView: NSViewRepresentable {
    let run: ActionOutput
    let theme: TerminalTheme

    func makeCoordinator() -> Coordinator { Coordinator(run: run) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.applyRackoonTheme(theme)
        view.feed(text: "\u{1B}[?25l")               // hide the cursor: nothing here accepts typing
        context.coordinator.themeID = theme.id
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        if context.coordinator.themeID != theme.id {
            view.applyRackoonTheme(theme)
            context.coordinator.themeID = theme.id
        }
        context.coordinator.feedNewChunks()
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let run: ActionOutput
        weak var view: TerminalView?
        var themeID = ""
        private var fed = 0

        init(run: ActionOutput) { self.run = run }

        func feedNewChunks() {
            guard let view else { return }
            let chunks = run.chunks
            while fed < chunks.count {
                view.feed(text: chunks[fed])
                fed += 1
            }
        }

        // The terminal's size becomes the remote pty's size when the run starts.
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in self.run.reportSize(cols: newCols, rows: newRows) }
        }
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {}     // read-only: typing goes nowhere
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            // Allow copying selected output with Cmd+C.
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(content, forType: .string)
            }
        }
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// A run's header (what it is and how it went, with Cancel while it runs and Close after) above its live terminal.
/// Used on the Docker detail page's Output tab and on the Updates screen.
struct ActionOutputPanel: View {
    let run: ActionOutput
    let theme: TerminalTheme
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                switch run.phase {
                case .starting, .running: ProgressView().controlSize(.small)
                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(Theme.warn)
                }
                Text(run.title).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Text(status).font(.system(size: 12)).foregroundStyle(statusColor)
                Spacer()
                if run.isRunning {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.bordered).controlSize(.small).handCursor()
                        .help("Stops the command on the server (Ctrl-C)")
                } else {
                    Button("Close", action: close).buttonStyle(.bordered).controlSize(.small).handCursor()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.sidebar.opacity(0.6))
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            OutputTerminalView(run: run, theme: theme).id(run.id)
                .padding(.leading, 6)
                .background(Color(nsColor: theme.backgroundRGB.nsColor))
        }
    }

    private var status: String {
        switch run.phase {
        case .starting: "Starting…"
        case .running: "Running"
        case .succeeded: "Finished"
        case .failed(let code): code.map { "Failed (exit \($0))" } ?? "Ended without a result"
        case .cancelled: "Cancelled"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch run.phase {
        case .starting, .running: Theme.textMuted
        case .succeeded: Theme.ok
        case .failed: Theme.danger
        case .cancelled: Theme.warn
        }
    }
}
