import RackoonCore
import SwiftUI

/// The Add container page (design: Docker page canvas, `Add.dc.html`): a form on the left that writes the compose.yaml
/// and .env shown on the right, with the server's checks underneath and Cancel / Save only / Create and start.
struct AddContainerScreen: View {
    let model: AddContainerModel
    let theme: TerminalTheme
    let back: () -> Void
    @State private var confirmDiscard = false
    @State private var changingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(alignment: .top, spacing: 20) {
                form.frame(width: 400)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)   // as tall as the form, so the buttons sit at its foot
            }
        }
        .onAppear { model.start() }
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
    }

    private func cancel() { if model.isDirty { confirmDiscard = true } else { back() } }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: cancel) { Text("Docker").foregroundStyle(Theme.accent) }
                    .buttonStyle(.pointer)
                    .confirmationDialog("Discard this container?", isPresented: $confirmDiscard) {
                        Button("Discard", role: .destructive) { back() }
                        Button("Keep Editing", role: .cancel) {}
                    } message: { Text("Nothing has been written to \(model.serverName) yet.") }
                Text("/").foregroundStyle(Theme.textMuted)
                Text("Add container").foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 13))
            Text("Add container").font(.system(size: 26, weight: .bold)).tracking(-0.4)
        }
    }

    // MARK: form

    private var form: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 18) {
            section("Add to") {
                Segmented(options: [(AddContainerModel.Target.newStack, "New stack"), (.existing, "Existing stack")], equalWidth: true,
                          selection: Binding(get: { model.target }, set: { model.setTarget($0) }))
                targetField
            }
            if let file = model.servicesInFile {
                servicesReadOut(file)
            } else {
            section("Container") {
                DesignField(text: $model.spec.name, placeholder: "container-name", hint: nil, mono: false, error: model.spec.nameProblem)
                    .onChange(of: model.spec.name) { _, _ in model.specChanged() }
                HStack(spacing: 8) {
                    DesignField(text: $model.spec.image, placeholder: "image:tag", hint: nil, mono: true, error: model.spec.imageProblem)
                        .onChange(of: model.spec.image) { _, _ in model.specChanged() }
                    imageStatus
                }
            }
            section("Ports", add: { model.spec.ports.append(PortRow()) }) {
                ForEach($model.spec.ports) { $row in
                    pairRow(removable: model.spec.ports.count > 1, remove: { model.spec.ports.removeAll { $0.id == row.id }; model.specChanged() }) {
                        DesignField(text: $row.host, placeholder: "8080", hint: nil, mono: true, error: nil, width: 120, border: portBorder(row))
                        Text("→").foregroundStyle(Theme.textMuted)
                        DesignField(text: $row.container, placeholder: "80", hint: nil, mono: true, error: nil, width: 90)
                        Text("TCP").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    if let p = ContainerSpec.portProblem(row) { problem(p) }
                }
            }
            section("Volumes", add: { model.spec.volumes.append(VolumeRow()) }) {
                ForEach($model.spec.volumes) { $row in
                    pairRow(removable: model.spec.volumes.count > 1, remove: { model.spec.volumes.removeAll { $0.id == row.id }; model.specChanged() }) {
                        DesignField(text: $row.source, placeholder: "./data", hint: nil, mono: true, error: nil)
                        Text("→").foregroundStyle(Theme.textMuted)
                        DesignField(text: $row.target, placeholder: "/app/data", hint: nil, mono: true, error: nil)
                    }
                    if let p = ContainerSpec.volumeProblem(row) { problem(p) }
                }
            }
            section("Environment", note: "saved to .env", add: { model.spec.env.append(EnvRow()) }) {
                ForEach($model.spec.env) { $row in
                    pairRow(removable: model.spec.env.count > 1, remove: { model.spec.env.removeAll { $0.id == row.id }; model.specChanged() }) {
                        DesignField(text: $row.key, placeholder: "NAME", hint: nil, mono: true, error: nil)
                        Text("=").foregroundStyle(Theme.textMuted)
                        DesignField(text: $row.value, placeholder: "value", hint: nil, mono: true, error: nil)
                    }
                    if let p = ContainerSpec.envProblem(row) { problem(p) }
                }
            }
            section("Restart") {
                Segmented(options: RestartPolicy.allCases.map { ($0, $0.label) },
                          selection: Binding(get: { model.spec.restart }, set: { model.spec.restart = $0; model.specChanged() }))
            }
            if model.formLocked {
                Label("The file has settings this form can't show, so edit it on the right, or choose Reset to form.", systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            }
        }
        .opacity(model.formLocked && model.servicesInFile == nil ? 0.55 : 1)
        .disabled(model.formLocked && model.servicesInFile == nil)
        // Row edits (ports, volumes, env) arrive through the bindings above.
        .onChange(of: model.spec.ports) { _, _ in model.specChanged() }
        .onChange(of: model.spec.volumes) { _, _ in model.specChanged() }
        .onChange(of: model.spec.env) { _, _ in model.specChanged() }
    }

    /// A pasted file with several services can't be edited through the one-container form, so show what it contains.
    private func servicesReadOut(_ file: ComposeFormParser.Overview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(file.services.count) SERVICES IN THIS FILE").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.services.enumerated()), id: \.offset) { index, service in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.name).font(.system(size: 13, weight: .semibold))
                        Text(service.image ?? (service.build ? "built from source" : "no image"))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                        if !service.ports.isEmpty {
                            Text("ports " + service.ports.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    if index < file.services.count - 1 { Divider().overlay(Theme.border) }
                }
            }
            .card()
            Label("This file has several services, so it is edited as text on the right. Add the .env it needs on the .env tab, then Create and start. Reset to form starts over.", systemImage: "doc.text")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var targetField: some View {
        @Bindable var model = model
        switch model.target {
        case .newStack:
            DesignField(text: $model.stackName, placeholder: "stack-name", hint: "Stack name, lowercase", mono: false, error: model.newStackNameProblem)
                .onChange(of: model.stackName) { _, _ in model.specChanged() }
            HStack(spacing: 6) {
                if changingFolder {
                    DesignField(text: $model.folder, placeholder: "/opt/stacks", hint: nil, mono: true, error: model.newStackFolderProblem)
                        .onChange(of: model.folder) { _, _ in model.specChanged() }
                } else {
                    Text(model.newStackFolderProblem ?? "Creates \(model.plannedDirectory)")
                        .font(.system(size: 12)).foregroundStyle(model.newStackFolderProblem == nil ? Theme.textMuted : Theme.danger).lineLimit(1).truncationMode(.middle)
                    Button("Change") { changingFolder = true }.buttonStyle(.pointer).font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
        case .existing:
            Menu {
                ForEach(model.existingCandidates) { stack in
                    Button(stack.name) { model.chooseExisting(stack.name) }
                }
            } label: {
                HStack {
                    Text(model.existingName ?? "Choose a stack").foregroundStyle(model.existingName == nil ? Theme.textMuted : Theme.textPrimary)
                    Spacer()
                    Text(model.existingName == nil ? "" : "compose.yaml").foregroundStyle(Theme.textMuted)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .disabled(model.existingCandidates.isEmpty)
            .handCursor()
        }
    }

    @ViewBuilder private var imageStatus: some View {
        switch ContainerChecks.imageRow(model.spec, status: model.imageStatusValue).state {
        case .pass: Label("Found", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ok).fixedSize()
        case .fail: Label("Not found", systemImage: "xmark").font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize()
        case .running: ProgressView().controlSize(.small)
        default: EmptyView()
        }
    }

    private func portBorder(_ row: PortRow) -> Color? {
        guard let port = row.hostPort, let listening = model.listening, listening.contains(port) else { return nil }
        return Theme.danger
    }

    private func section<Content: View>(_ title: String, note: String? = nil, add: (() -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.textMuted)
                Spacer()
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.trailing, 6) }
                if let add { Button("+ Add", action: add).buttonStyle(.pointer).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            }
            content()
        }
    }

    private func pairRow<Content: View>(removable: Bool, remove: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            if removable {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.pointer).foregroundStyle(Theme.textMuted).help("Remove this row")
            }
        }
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.danger)
    }

    // MARK: preview

    private var preview: some View {
        let failing = model.rows.contains { $0.state == .fail }
        return VStack(spacing: 0) {
            tabBar
            if let notice = model.notice {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                    Text(notice).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.danger.opacity(0.12))
                .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
            }
            let tab = model.tab
            CodeEditorView(text: Binding(get: { model.text(tab) }, set: { model.setText($0, for: tab) }),
                           isEnv: tab == .env, theme: theme, changedLines: model.changedLines(tab), errorLines: model.errorLines(tab))
                .id("\(model.target)-\(model.existingName ?? "")-\(tab)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            EditorChecksList(rows: model.rows)
            missingVariablesBar
            footer
        }
        .frame(minHeight: 560)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(failing ? Theme.danger.opacity(0.45) : Theme.border))
    }

    /// Compose says the file uses variables `.env` doesn't set (a file like Immich's): one click adds them, ready to fill in.
    @ViewBuilder private var missingVariablesBar: some View {
        let missing = model.missingVariables
        if !missing.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "key").foregroundStyle(Theme.warn)
                Text(missingText(missing))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("Add to .env") { model.addMissingVariables() }.buttonStyle(.bordered).controlSize(.small).handCursor()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.warn.opacity(0.08))
            .overlay(alignment: .top) { Theme.border.frame(height: 1) }
        }
    }

    private func missingText(_ missing: [String]) -> String {
        let count = missing.count
        let noun = count == 1 ? "variable" : "variables"
        let verb = count == 1 ? "isn't" : "aren't"
        let names = missing.prefix(4).joined(separator: ", ")
        let more = count > 4 ? " and \(count - 4) more" : ""
        return "The file uses \(count) \(noun) that \(verb) set in .env: \(names)\(more)."
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton("compose.yaml", .compose)
            tabButton(".env", .env)
            Spacer()
            if model.isHandEdited {
                Button("Reset to form") { model.resetToForm() }.buttonStyle(.pointer).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .padding(.trailing, 8)
            }
            Text(model.fileCaption).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 42)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private func tabButton(_ label: String, _ tab: AddContainerModel.Tab) -> some View {
        Button { model.tab = tab } label: {
            Text(label).font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(model.tab == tab ? Theme.textPrimary : Theme.textMuted)
                .background(model.tab == tab ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.pointer)
    }

    private var footer: some View {
        let blocked = model.deployBlockedReason
        return HStack(spacing: 10) {
            Text(model.footnote).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(2)
            Spacer()
            if model.creating { ProgressView().controlSize(.small) }
            // The cursor modifier must sit before `.disabled` to see that the button is off.
            Button("Cancel") { cancel() }.handCursor().disabled(model.creating)
            Button("Save only") { model.request(start: false) }
                .handCursor().disabled(blocked != nil)
                .help(blocked ?? "Write the files without starting anything")
            Button("Create and start") { model.request(start: true) }
                .buttonStyle(.borderedProminent).handCursor().disabled(blocked != nil)
                .help(blocked ?? "Write the files, then start the container with docker compose up -d")
        }
        .buttonStyle(.bordered).controlSize(.large)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }
}

// MARK: - Controls from the design

/// A text field drawn like the design's: dark fill, thin border, an optional hint at the right edge.
private struct DesignField: View {
    @Binding var text: String
    let placeholder: String
    let hint: String?
    let mono: Bool
    let error: String?
    var width: CGFloat? = nil
    var border: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                if let hint { Text(hint).font(.system(size: 13)).foregroundStyle(Theme.textMuted).lineLimit(1) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border ?? (error == nil ? Theme.border : Theme.danger)))
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

/// The design's segmented control: a recessed track with the selected option raised.
private struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    /// Every segment the same width (two short options); otherwise a long label gets the room it needs first.
    var equalWidth = false
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                Button { selection = value } label: {
                    Text(label).font(.system(size: 12.5)).lineLimit(1).fixedSize(horizontal: !equalWidth, vertical: false)
                        .padding(.horizontal, 12)          // inside the frame, so a long label keeps room around it
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .foregroundStyle(selection == value ? Theme.textPrimary : Theme.textMuted)
                        .background(selection == value ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.pointer)
                .layoutPriority(equalWidth ? 0 : Double(label.count))   // a long label gets the room it needs before the others share the rest
            }
        }
        .padding(3)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }
}
