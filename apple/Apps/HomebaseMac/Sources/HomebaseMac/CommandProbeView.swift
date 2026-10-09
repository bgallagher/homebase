import HomebaseCore
import HomebaseSSHSystem
import SwiftUI

/// Stage 1 slice: run one command over SSH and show the result.
struct CommandProbeView: View {
    let host: String
    @State private var command = "uname -a"
    @State private var output = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(run)
                Button("Run", action: run)
                    .disabled(running || host.isEmpty)
            }
            ScrollView {
                Text(output.isEmpty ? "No output yet" : output)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    private func run() {
        running = true
        let transport = OpenSSHTransport(host: host)
        let command = command
        Task {
            defer { running = false }
            do {
                let start = Date()
                let r = try await transport.run(command, timeout: 15)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                output = r.stdout + (r.stderr.isEmpty ? "" : "\n[stderr]\n" + r.stderr)
                    + "\n[exit \(r.exitCode) · \(ms) ms]"
            } catch {
                output = "Error: \(error.localizedDescription)"
            }
        }
    }
}
