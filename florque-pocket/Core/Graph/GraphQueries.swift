import Foundation
import SwiftData

// Purpose: the queries the chat's retrieve tool and the Memory tab need on the graph, plus the small writes the
// reminder and link-review flows use. Reads return value copies; writes go through `commit` like the rest of the store.
//
// Testing: `GraphQueriesTests` covers search by words, type and date range, the strongest neighbour, and link review.

extension PocketStore {
    /// Accepted nodes whose title, aliases or body contain `text` (nil matches all), optionally of one type and with a
    /// due time in `from`...`to`. Most recently updated first.
    public func searchNodes(text: String?, typeKey: String?, from: Date?, to: Date?, limit: Int) throws -> [NodeRecord] {
        let needle = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = try modelContext.fetch(FetchDescriptor<Node>())
            .filter { $0.status == "accepted" }
            .filter { typeKey == nil || $0.typeKey == typeKey }
            .filter { node in
                if let from, (node.dueAt ?? .distantPast) < from { return false }
                if let to, (node.dueAt ?? .distantFuture) > to { return false }
                return true
            }
            .filter { node in
                guard let needle, !needle.isEmpty else { return true }
                return node.title.localizedStandardContains(needle)
                    || node.aliases.contains { $0.localizedStandardContains(needle) }
                    || node.body.localizedStandardContains(needle)
            }
        return matches.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit).map(NodeRecord.init)
    }

    /// The node linked to `id` by the most recent accepted edge, if any: the one-hop neighbour the retrieve tool adds.
    public func strongestNeighbour(of id: UUID) throws -> NodeRecord? {
        let edge = try modelContext.fetch(FetchDescriptor<Edge>())
            .filter { $0.status == "accepted" && ($0.fromId == id || $0.toId == id) }
            .max { $0.createdAt < $1.createdAt }
        guard let edge else { return nil }
        let other = edge.fromId == id ? edge.toId : edge.fromId
        return try node(id: other)
    }

    /// Records the Apple Reminders identifier of a node, once its reminder exists.
    public func setNodeEventId(_ eventId: String, nodeId: UUID) throws {
        try commit {
            guard let node = try modelContext.fetch(FetchDescriptor<Node>(predicate: #Predicate { $0.id == nodeId })).first else {
                throw GraphStoreError.unknownNode(nodeId)
            }
            node.eventId = eventId
        }
    }

    /// Accepts or dismisses a proposed link. Dismissing deletes it.
    public func reviewEdge(id: UUID, accept: Bool) throws {
        try commit {
            guard let edge = try modelContext.fetch(FetchDescriptor<Edge>(predicate: #Predicate { $0.id == id })).first else {
                return
            }
            if accept {
                edge.status = "accepted"
            } else {
                modelContext.delete(edge)
            }
        }
    }
}
