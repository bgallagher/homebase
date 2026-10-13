import AppKit
import RackoonCore
import RackoonSSHSystem
import SwiftUI

/// What the Add (manual) and Edit forms hold, as typed. `ServerInput.problem` (Core) says what is wrong with it.
struct ServerFormFields: Equatable {
    var name = ""
    var host = ""
    var user = ""
    var port = ""
    var identityFile = ""

    init() {}

    init(_ server: Server) {
        name = server.name
        host = server.host
        user = server.user ?? ""
        port = server.port.map(String.init) ?? ""
        identityFile = server.identityFile ?? ""
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    var problem: String? { ServerInput.problem(host: host, user: user, port: port, identityFile: identityFile) }

    /// The server as typed. With `original`, its id is kept, and so is the ~/.ssh/config link while the host is still
    /// that alias (changing the host to anything else drops it: ssh would no longer apply the entry).
    func server(basedOn original: Server? = nil) -> Server {
        let h = trimmedHost
        let n = name.trimmingCharacters(in: .whitespaces)
        let u = user.trimmingCharacters(in: .whitespaces)
        let key = identityFile.trimmingCharacters(in: .whitespaces)
        let alias = original?.sshConfigAlias == h ? original?.sshConfigAlias : nil
        return Server(id: original?.id ?? UUID().uuidString, name: n.isEmpty ? h : n, host: h, user: u.isEmpty ? nil : u,
                      port: Int(port.trimmingCharacters(in: .whitespaces)), sshConfigAlias: alias, identityFile: key.isEmpty ? nil : key)
    }
}

/// The fields of a server, shared by Add (manual) and Edit Connection.
struct ServerForm: View {
    @Binding var fields: ServerFormFields
    /// The saved server when editing, for the ~/.ssh/config note.
    var original: Server?

    var body: some View {
        Form {
            TextField("Name", text: $fields.name, prompt: Text("optional"))
            TextField("Host", text: $fields.host, prompt: Text("example.com, 203.0.113.7 or a ~/.ssh/config alias"))
            TextField("User", text: $fields.user, prompt: Text("optional"))
            TextField("Port", text: $fields.port, prompt: Text("22"))
            LabeledContent("Key file") {
                HStack(spacing: 8) {
                    TextField("Key file", text: $fields.identityFile, prompt: Text("optional: ssh's default keys and ssh-agent"))
                        .labelsHidden()
                    Button("Choose…", action: choose).handCursor()
                }
            }
            if let alias = original?.sshConfigAlias, alias == fields.trimmedHost {
                Text("Imported from ~/.ssh/config as \(alias): ssh also applies that entry (HostName, User, Port, IdentityFile).")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            Text("Rackoon logs in with keys only and never asks for a password or passphrase. A key with a passphrase must be loaded in ssh-agent (ssh-add --apple-use-keychain).")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // key files live in a dot folder
        panel.directoryURL = URL(fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath, isDirectory: true)
        panel.message = "Choose the private key file for this server (the one without .pub)."
        if panel.runModal() == .OK, let url = panel.url {
            fields.identityFile = NSString(string: url.path).abbreviatingWithTildeInPath
        }
    }
}

struct AddServerSheet: View {
    let existing: [Server]
    let canCancel: Bool
    let onAdd: (Server) -> Void
    let onCancel: () -> Void

    private enum Mode: String, CaseIterable { case sshConfig = "From ~/.ssh/config", manual = "Manual" }

    @State private var mode: Mode = .sshConfig
    @State private var configHosts: [SSHConfigHost] = []
    @State private var fields = ServerFormFields()

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
                if canCancel { Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction) }
                if mode == .manual {
                    Button("Add") { onAdd(fields.server()) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(fields.problem != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
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
        VStack(alignment: .leading, spacing: 8) {
            ServerForm(fields: $fields)
            // Only once something is typed: an empty form is not yet wrong.
            if !fields.host.isEmpty, let problem = fields.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
        }
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

/// Edit a saved server's connection details. Saving reconnects when they changed (see `AppModel.update`).
struct EditServerSheet: View {
    let server: Server
    let onSave: (Server) -> Void
    let onCancel: () -> Void
    @State private var fields: ServerFormFields

    init(server: Server, onSave: @escaping (Server) -> Void, onCancel: @escaping () -> Void) {
        self.server = server
        self.onSave = onSave
        self.onCancel = onCancel
        _fields = State(initialValue: ServerFormFields(server))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit connection").font(.title2.bold())
            ServerForm(fields: $fields, original: server)
            if let problem = fields.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(fields.server(basedOn: server)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fields.problem != nil || fields == ServerFormFields(server))
            }
        }
        .padding(24)
        .frame(width: 520)
        .foregroundStyle(Theme.textPrimary)
        .background(Theme.background)
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
