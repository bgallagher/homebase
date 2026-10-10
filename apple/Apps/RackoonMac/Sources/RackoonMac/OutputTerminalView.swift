import AppKit
import RackoonCore
import SwiftTerm
import SwiftUI

/// A read-only terminal showing a streamed run. It is a real terminal emulator, so compose's own progress (the lines
/// that redraw as containers stop and start) looks exactly as it does in a terminal. Use `.id(run.id)` so a new run
/// gets a fresh screen.
struct OutputTerminalView: NSViewRepresentable {
    let run: StackOutput
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
        let run: StackOutput
        weak var view: TerminalView?
        var themeID = ""
        private var fed = 0

        init(run: StackOutput) { self.run = run }

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
