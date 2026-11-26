import SwiftUI

// Purpose: the app's Settings screen. Its Memory section lists node types and edge types in two groups, lets the
// user turn each one on or off, and opens an editor to change one or add a new one.
//
// Testing: manual on a simulator (Settings, toggle a type, add one, delete one). Rules are in `GraphStoreTests`.

struct SettingsScreen: View {
    @State private var model: MemorySettingsModel
    @State private var addingNode = false
    @State private var addingEdge = false

    init(store: PocketStore) {
        _model = State(initialValue: MemorySettingsModel(store: store))
    }

    var body: some View {
        List {
            Section {
                ForEach(model.nodeTypes) { type in
                    HStack {
                        NavigationLink {
                            NodeTypeEditor(model: model, existing: type)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.name)
                                Text(type.typeDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(type.onDeviceOnly ? "On this device only" : "Cloud allowed")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Enabled", isOn: Binding(
                            get: { type.enabled },
                            set: { value in Task { await model.setNodeType(type.key, enabled: value) } }
                        ))
                        .labelsHidden()
                    }
                }
                Button("Add node type") { addingNode = true }
                    .disabled(!model.canAddNodeType)
            } header: {
                Text("Memory: nodes")
            } footer: {
                Text("Nodes are the things Pocket remembers. \(model.customNodeCount) of \(GraphDefaults.maxCustomNodeTypes) custom types used.")
            }

            Section {
                ForEach(model.edgeTypes) { type in
                    HStack {
                        NavigationLink {
                            EdgeTypeEditor(model: model, existing: type)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(type.name) / \(type.inverseName)")
                                Text(type.typeDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(endpointSummary(type))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Enabled", isOn: Binding(
                            get: { type.enabled },
                            set: { value in Task { await model.setEdgeType(type.key, enabled: value) } }
                        ))
                        .labelsHidden()
                    }
                }
                Button("Add link type") { addingEdge = true }
                    .disabled(!model.canAddEdgeType)
            } header: {
                Text("Memory: links")
            } footer: {
                Text("Links connect two nodes. \(model.customEdgeCount) of \(GraphDefaults.maxCustomEdgeTypes) custom types used.")
            }

            if let message = model.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .task { await model.load() }
        .sheet(isPresented: $addingNode) {
            NavigationStack {
                NodeTypeEditor(model: model, existing: nil)
            }
        }
        .sheet(isPresented: $addingEdge) {
            NavigationStack {
                EdgeTypeEditor(model: model, existing: nil)
            }
        }
    }

    private func endpointSummary(_ type: EdgeTypeRecord) -> String {
        if type.symmetric { return "Two-way" }
        let from = type.fromNodeKeys.isEmpty ? "any" : type.fromNodeKeys.joined(separator: ", ")
        let to = type.toNodeKeys.isEmpty ? "any" : type.toNodeKeys.joined(separator: ", ")
        return "\(from) → \(to)"
    }
}
