import HomebaseCore
import HomebaseSSHSystem
import SwiftUI

struct AddServerSheet: View {
    let existing: [Server]
    let canCancel: Bool
    let onAdd: (Server) -> Void
    let onCancel: () -> Void

    private enum Mode: String, CaseIterable { case sshConfig = "From ~/.ssh/config", manual = "Manual" }

    @State private var mode: Mode = .sshConfig
    @State private var configHosts: [SSHConfigHost] = []
    @State private var name = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add server").font(.title2.bold())
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch mode {
            case .sshConfig: sshConfigList
            case .manual: manualForm
            }

            HStack {
                Spacer()
                if canCancel { Button("Cancel", action: onCancel) }
                if mode == .manual {
                    Button("Add", action: addManual)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!manualValid)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.background)
        .onAppear(perform: loadConfig)
    }

    private var sshConfigList: some View {
        Group {
            if configHosts.isEmpty {
                Text("No hosts found in ~/.ssh/config. Use Manual to add one.")
                    .foregroundStyle(Theme.textMuted).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(configHosts, id: \.alias) { h in
                            let added = existing.contains { $0.host == h.alias }
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.alias).fontWeight(.semibold)
                                    Text(detail(h)).font(.caption).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                Button(added ? "Added" : "Add") { onAdd(h.asServer()) }.disabled(added)
                            }
                            .padding(10).card()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private var manualForm: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("optional"))
            TextField("Host", text: $host, prompt: Text("example.com or 203.0.113.7"))
            TextField("User", text: $user, prompt: Text("optional"))
            TextField("Port", text: $port, prompt: Text("22"))
        }
    }

    private var manualValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (port.isEmpty || Int(port) != nil)
    }

    private func addManual() {
        let h = host.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        let u = user.trimmingCharacters(in: .whitespaces)
        onAdd(Server(name: n.isEmpty ? h : n, host: h, user: u.isEmpty ? nil : u, port: Int(port)))
    }

    private func detail(_ h: SSHConfigHost) -> String {
        var s = ""
        if let u = h.user { s += "\(u)@" }
        s += h.hostName ?? h.alias
        if let p = h.port { s += ":\(p)" }
        return s
    }

    private func loadConfig() {
        let path = NSString(string: "~/.ssh/config").expandingTildeInPath
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            configHosts = SSHConfigParser.parse(text)
        }
        if configHosts.isEmpty { mode = .manual }
    }
}

struct HostKeySheet: View {
    let server: Server
    let offer: HostKeyOffer
    let onTrust: () -> Void
    let onCancel: () -> Void

    private var explanation: String {
        "This is the first time connecting to \(server.name) (\(offer.hostname):\(offer.port)). "
            + "Check that these fingerprints match your server, for example with ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Trust this server?", systemImage: "lock.shield").font(.title2.bold())
            Text(explanation)
                .foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(offer.fingerprints, id: \.self) { fp in
                    Text(fp).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Trust and Connect", action: onTrust).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.background)
    }
}
