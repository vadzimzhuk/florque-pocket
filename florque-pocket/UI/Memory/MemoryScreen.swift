import SwiftUI

// Purpose: the Memory tab. Lists every accepted node, newest first, with its type icon and link count. A menu
// filters by node type, the search field matches title, aliases and body, and a row opens the entry detail.
//
// Testing: manual on a simulator; filtering and search logic is in `MemoryModel` and tested by `MemoryModelTests`.

struct MemoryScreen: View {
    @State private var model: MemoryModel
    private let store: PocketStore

    init(store: PocketStore) {
        self.store = store
        _model = State(initialValue: MemoryModel(store: store))
    }

    var body: some View {
        NavigationStack {
            List {
                if model.visible.isEmpty {
                    ContentUnavailableView(
                        model.nodes.isEmpty ? "Nothing remembered yet" : "No matches",
                        systemImage: "brain",
                        description: Text(model.nodes.isEmpty
                            ? "Tell Pocket something in the chat and it will show up here."
                            : "Try another word or filter.")
                    )
                }
                ForEach(model.visible) { node in
                    NavigationLink(value: node.id) {
                        HStack(spacing: 12) {
                            Image(systemName: MemoryModel.icon(for: node.typeKey))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title)
                                Text(subtitle(for: node))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Memory")
            .searchable(text: $model.query, prompt: "Search memory")
            .navigationDestination(for: UUID.self) { id in
                EntryDetailScreen(store: store, nodeId: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Type", selection: $model.typeFilter) {
                            Text("All types").tag(String?.none)
                            ForEach(model.types) { type in
                                Text(type.name).tag(String?.some(type.key))
                            }
                        }
                    } label: {
                        Image(systemName: model.typeFilter == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
        }
    }

    private func subtitle(for node: NodeRecord) -> String {
        let type = model.typeName(node.typeKey)
        let links = model.linkCounts[node.id, default: 0]
        return links == 1 ? "\(type) · 1 link" : "\(type) · \(links) links"
    }
}
