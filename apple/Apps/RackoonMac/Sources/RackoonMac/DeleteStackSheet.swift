import RackoonCore
import SwiftUI

/// Confirmation for deleting a stack: what is removed, two opt-in extras that lose data (volumes, the stack's folder), the
/// exact command, and for the extras a typed name, so a stray click can't wipe data.
struct DeleteStackSheet: View {
    let stack: DockerStack
    let serverName: String
    let cancel: () -> Void
    let run: (StackRemoval) -> Void
    @State private var removeVolumes = false
    /// On by default, so a deleted stack leaves nothing behind (Dockge does the same); off when the folder can't safely be deleted.
    @State private var deleteFolder: Bool
    @State private var typed = ""

    init(stack: DockerStack, serverName: String, cancel: @escaping () -> Void, run: @escaping (StackRemoval) -> Void) {
        self.stack = stack
        self.serverName = serverName
        self.cancel = cancel
        self.run = run
        _deleteFolder = State(initialValue: StackRemoval.folderProblem(for: stack) == nil)
    }

    private var removal: StackRemoval { StackRemoval(removeVolumes: removeVolumes, deleteFolder: deleteFolder) }
    private var folderProblem: String? { StackRemoval.folderProblem(for: stack) }
    private var command: String { removal.command(for: stack) ?? "" }
    private var confirmed: Bool { !removal.losesData || typed == stack.name }

    var body: some View {
        let n = stack.containers.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(Theme.warn)
                Text("Delete \(stack.name)?").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text(n == 0
                 ? "Removes the stack's networks. It has no containers right now. Images are kept. Its folder is deleted too unless you untick that below."
                 : "Stops and removes its \(n) container\(n == 1 ? "" : "s") and the networks Compose made for it. Images are kept. Its folder is deleted too unless you untick that below.")
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $removeVolumes) {
                    option("Also delete its named volumes", "Data kept in Docker volumes is lost for good.")
                }
                Toggle(isOn: $deleteFolder) {
                    option("Also delete its folder on \(serverName)",
                           folderProblem ?? "\(stack.workingDir ?? "") and everything in it: compose.yaml, .env and bind-mounted data such as ./data.")
                }
                .disabled(folderProblem != nil)
            }
            .toggleStyle(.checkbox)
            .handCursor()

            VStack(alignment: .leading, spacing: 6) {
                Text("RUNS ON \(serverName.uppercased())")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }

            if removal.losesData {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type \(stack.name) to confirm").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    TextField(stack.name, text: $typed).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                Button("Delete Stack") { run(removal) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.danger)
                    .disabled(!confirmed || command.isEmpty)
            }
            .controlSize(.large)
            .handCursor()
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(AppearanceStore.shared.fixedColorScheme)
    }

    private func option(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Confirmation for deleting a standalone container (started with `docker run`): what is removed and what is kept, an
/// opt-in for its anonymous volumes, the exact command, and always a typed name, because nothing on the server can create
/// the container again (its settings were only in the original command line).
struct DeleteContainerSheet: View {
    let stack: DockerStack
    let serverName: String
    let cancel: () -> Void
    let run: (_ volumes: Bool) -> Void
    @State private var removeVolumes = false
    @State private var typed = ""

    private var command: String { StandaloneAction.remove(volumes: removeVolumes).command(for: stack) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(Theme.warn)
                Text("Delete \(stack.name)?").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            Text("Stops and removes the container. It was started with docker run, not Docker Compose, so it can't be created again from here: that needs its original docker run command. Its image, named volumes and bind-mounted folders are kept.")
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $removeVolumes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also delete its anonymous volumes").foregroundStyle(Theme.textPrimary)
                    Text("Volumes Docker made for it without a name are lost for good. Named volumes are kept.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .handCursor()

            VStack(alignment: .leading, spacing: 6) {
                Text("RUNS ON \(serverName.uppercased())")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
                Text(command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type \(stack.name) to confirm").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                TextField(stack.name, text: $typed).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                Button("Delete Container") { run(removeVolumes) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.danger)
                    .disabled(typed != stack.name || command.isEmpty)
            }
            .controlSize(.large)
            .handCursor()
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(AppearanceStore.shared.fixedColorScheme)
    }
}
