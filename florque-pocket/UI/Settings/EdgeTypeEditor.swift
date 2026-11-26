import SwiftUI

// Purpose: edit or create one link type: its name and inverse name, the "when to use" line, the node types it may
// start and end at (none selected means any), and whether it is two-way. Custom types can be deleted; their links
// move to "Related".
//
// Testing: manual on a simulator. Rules (caps, endpoint checks, reassignment) are in `GraphStoreTests`.

struct EdgeTypeEditor: View {
    let model: MemorySettingsModel
    let existing: EdgeTypeRecord?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var inverseName: String
    @State private var typeDescription: String
    @State private var fromKeys: Set<String>
    @State private var toKeys: Set<String>
    @State private var symmetric: Bool
    @State private var confirmDelete = false

    init(model: MemorySettingsModel, existing: EdgeTypeRecord?) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _inverseName = State(initialValue: existing?.inverseName ?? "")
        _typeDescription = State(initialValue: existing?.typeDescription ?? "")
        _fromKeys = State(initialValue: Set(existing?.fromNodeKeys ?? []))
        _toKeys = State(initialValue: Set(existing?.toNodeKeys ?? []))
        _symmetric = State(initialValue: existing?.symmetric ?? false)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedInverse: String { inverseName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDescription: String { typeDescription.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var charactersLeft: Int { GraphDefaults.maxDescriptionLength - typeDescription.count }
    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedInverse.isEmpty && !trimmedDescription.isEmpty && charactersLeft >= 0
    }

    var body: some View {
        Form {
            Section("Names") {
                TextField("Name, e.g. Participates", text: $name)
                TextField("Inverse name, e.g. Has participant", text: $inverseName)
            }
            Section {
                TextField("Describe when Pocket should use this", text: $typeDescription, axis: .vertical)
                    .lineLimit(2...4)
                HStack {
                    Spacer()
                    Text("\(charactersLeft)")
                        .font(.caption)
                        .foregroundStyle(charactersLeft < 0 ? .red : .secondary)
                }
            } header: {
                Text("When to use")
            }
            Section {
                ForEach(model.nodeTypes) { type in
                    selectionRow(type.name, selected: fromKeys.contains(type.key)) { toggle(type.key, in: $fromKeys) }
                }
            } header: {
                Text("From")
            } footer: {
                Text("Select none to allow any node type.")
            }
            Section {
                ForEach(model.nodeTypes) { type in
                    selectionRow(type.name, selected: toKeys.contains(type.key)) { toggle(type.key, in: $toKeys) }
                }
            } header: {
                Text("To")
            } footer: {
                Text("Select none to allow any node type.")
            }
            Section {
                Toggle("Two-way link", isOn: $symmetric)
            } footer: {
                Text("A two-way link has no direction, so the inverse name and the From and To lists are not used.")
            }
            if let existing, !existing.isDefault {
                Section {
                    Button("Delete type", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Links of this type become Related.")
                }
            }
        }
        .navigationTitle(existing == nil ? "New link type" : "Link type")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        let draft = EdgeTypeDraft(key: existing?.key, name: trimmedName, inverseName: trimmedInverse,
                                                  typeDescription: trimmedDescription,
                                                  fromNodeKeys: fromKeys.sorted(), toNodeKeys: toKeys.sorted(),
                                                  symmetric: symmetric, enabled: existing?.enabled ?? true)
                        if await model.saveEdgeType(draft) { dismiss() }
                    }
                }
                .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete this link type?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if let key = existing?.key, await model.deleteEdgeType(key) { dismiss() }
                }
            }
        } message: {
            Text("Its links move to Related. This cannot be undone.")
        }
    }

    private func selectionRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func toggle(_ key: String, in set: Binding<Set<String>>) {
        if set.wrappedValue.contains(key) {
            set.wrappedValue.remove(key)
        } else {
            set.wrappedValue.insert(key)
        }
    }
}
