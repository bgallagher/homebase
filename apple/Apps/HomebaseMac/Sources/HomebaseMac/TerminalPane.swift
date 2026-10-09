import AppKit
import SwiftTerm
import SwiftUI

/// Stage 1 risk spike: SwiftTerm running `ssh -t <host>` over a PTY.
/// Check vim, htop and `docker logs -f` here before building on it.
struct TerminalPane: NSViewRepresentable {
    let host: String

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.startProcess(
            executable: "/usr/bin/ssh",
            args: ["-t", host],
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
        )
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        nsView.terminate()
    }
}
