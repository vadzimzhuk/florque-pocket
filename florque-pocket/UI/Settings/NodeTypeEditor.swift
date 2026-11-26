import SwiftUI

// Purpose: edit or create one node type: its name, the "when to use" line Pocket reads, and its two flags. Person
// and feeling are always on this device. Custom types can be deleted, and their items move to Note.
//
// Testing: manual on a simulator. Rules (caps, locks, reassignment) are in `GraphStoreTests`.

struct NodeTypeEditor: View {
    let model: MemorySettingsModel
    let existing: NodeTypeRecord?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var typeDescription: String
    @State private var onDeviceOnly: Bool
    @State private var schedulesReminder: Bool
    @State private var confirmDelete = false

    init(model: MemorySettingsModel, existing: NodeTypeRecord?) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _typeDescription = State(initialValue: existing?.typeDescription ?? "")
        _onDeviceOnly = State(initialValue: existing?.onDeviceOnly ?? false)
        _schedulesReminder = State(initialValue: existing?.schedulesReminder ?? false)
    }

    private var locked: Bool { existing.map { PocketStore.lockedOnDevice.contains($0.key) } ?? false }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDescription: String { typeDescription.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var charactersLeft: Int { GraphDefaults.maxDescriptionLength - typeDescription.count }
    private var canSave: Bool {
        !trimmedName.isEmpty && !trimmedDescription.isEmpty && charactersLeft >= 0
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
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
            } footer: {
                Text("Pocket reads this line to decide what to record.")
            }
            Section {
                Toggle("On this device only", isOn: $onDeviceOnly)
                    .disabled(locked)
                Toggle("Schedules a reminder", isOn: $schedulesReminder)
            } footer: {
                if locked {
                    Text("Person and feeling always stay on this device.")
                }
            }
            if let existing, !existing.isDefault {
                Section {
                    Button("Delete type", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Items of this type move to Note.")
                }
            }
        }
        .navigationTitle(existing == nil ? "New node type" : "Node type")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        let draft = NodeTypeDraft(key: existing?.key, name: trimmedName,
                                                  typeDescription: trimmedDescription,
                                                  onDeviceOnly: onDeviceOnly, schedulesReminder: schedulesReminder,
                                                  enabled: existing?.enabled ?? true)
                        if await model.saveNodeType(draft) { dismiss() }
                    }
                }
                .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete this node type?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    if let key = existing?.key, await model.deleteNodeType(key) { dismiss() }
                }
            }
        } message: {
            Text("Its items move to Note. This cannot be undone.")
        }
    }
}
