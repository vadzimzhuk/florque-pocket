import Foundation
import Observation

// Purpose: state for the Memory tab's list: the accepted nodes, the node types, how many links each node has, the
// type filter and the search text. Holds value copies; the store does the reads.
//
// Testing: `MemoryModelTests` covers filtering, search and the link counts.

@MainActor
@Observable
final class MemoryModel {
    private let store: PocketStore
    private(set) var nodes: [NodeRecord] = []
    private(set) var types: [NodeTypeRecord] = []
    private(set) var linkCounts: [UUID: Int] = [:]
    var typeFilter: String?
    var query = ""

    init(store: PocketStore) {
        self.store = store
    }

    func load() async {
        do {
            types = try await store.nodeTypes()
            nodes = try await store.nodes().filter { $0.status == "accepted" }
            var counts: [UUID: Int] = [:]
            for edge in try await store.edges() where edge.status == "accepted" {
                counts[edge.fromId, default: 0] += 1
                counts[edge.toId, default: 0] += 1
            }
            linkCounts = counts
        } catch {
            nodes = []
        }
    }

    /// Nodes after the type filter and the search, most recently updated first.
    var visible: [NodeRecord] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return nodes
            .filter { typeFilter == nil || $0.typeKey == typeFilter }
            .filter { node in
                guard !text.isEmpty else { return true }
                return node.title.localizedStandardContains(text)
                    || node.aliases.contains { $0.localizedStandardContains(text) }
                    || node.body.localizedStandardContains(text)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func typeName(_ key: String) -> String {
        types.first { $0.key == key }?.name ?? key.capitalized
    }

    /// An SF Symbol for each default type; custom types get a tag.
    static func icon(for typeKey: String) -> String {
        switch typeKey {
        case "note": "note.text"
        case "event": "calendar"
        case "task": "checkmark.circle"
        case "person": "person"
        case "feeling": "heart"
        default: "tag"
        }
    }
}
