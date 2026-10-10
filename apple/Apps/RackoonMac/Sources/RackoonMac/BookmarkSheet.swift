import RackoonCore
import SwiftUI

/// The modal for adding, editing or removing a service's bookmark. The bookmark is stored as Homepage-convention labels
/// in the stack's compose.yaml, so it travels with the stack.
struct BookmarkSheet: View {
    let model: BookmarkModel
    let cancel: () -> Void

    var body: some View {
        @Bindable var model = model
        let blocked = model.saveBlockedReason
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.existing == nil ? "bookmark" : "bookmark.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                Text(model.existing == nil ? "Add bookmark" : "Edit bookmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }

            if !model.stackLocked {
                labelled("Stack") {
                    Picker("Stack", selection: Binding(get: { model.stack?.name ?? "" }, set: { name in
                        if let s = model.choices.first(where: { $0.name == name }) { model.choose(s) }
                    })) {
                        if model.stack == nil { Text("Choose a stack").tag("") }
                        ForEach(model.choices) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                }
            }
            if model.services.count > 1 {
                labelled("Container") {
                    Picker("Container", selection: Binding(get: { model.service }, set: { model.choose(service: $0) })) {
                        ForEach(model.services, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            } else if model.stack != nil, !model.service.isEmpty, !model.stackLocked {
                Text("Container: \(model.service)").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }

            labelled("Web address", problem: model.urlProblem) {
                TextField("https://app.example.com", text: $model.url).font(.system(size: 13, design: .monospaced))
            }
            HStack(alignment: .top, spacing: 12) {
                labelled("Name") { TextField(model.service.isEmpty ? "Name" : model.service, text: $model.name) }
                labelled("Group") {
                    HStack(spacing: 6) {
                        TextField("Media", text: $model.group)
                        if !model.groups.isEmpty {
                            Menu {
                                ForEach(model.groups, id: \.self) { g in Button(g) { model.group = g } }
                            } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Existing groups")
                        }
                    }
                }
            }
            labelled("Icon (optional)") { TextField("name.png, or a dashboard-icons name", text: $model.icon) }
            labelled("Description (optional)") { TextField("What it is", text: $model.details) }

            Text("Saved as Homepage labels (homepage.href, homepage.name, …) in the stack's compose.yaml, so other tools that read them see it too.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)

            if let notice = model.notice {
                Label(notice, systemImage: "xmark.octagon.fill").font(.system(size: 12)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if model.existing != nil {
                    Button("Remove Bookmark", role: .destructive) { model.requestRemoval() }
                        .disabled(model.busy || SafetyStore.shared.readOnly)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save Only") { model.requestSave(apply: false) }
                    .disabled(blocked != nil).help(blocked ?? "Write the labels to compose.yaml without restarting anything")
                Button("Save and Apply") { model.requestSave(apply: true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(blocked != nil).help(blocked ?? "Write the labels, then update the stack (recreates the container)")
            }
            .buttonStyle(.bordered).controlSize(.large)
            .handCursor()
            if let blocked, model.stack != nil, !model.url.isEmpty {
                Text(blocked).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 500)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(AppearanceStore.shared.fixedColorScheme)
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
    }

    private func labelled<Content: View>(_ title: String, problem: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
            content()
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
