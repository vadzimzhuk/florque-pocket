import Foundation
import SwiftData

public enum SwiftDataGraphStoreError: Error, Equatable {
    case missingEndpoint(from: String, to: String)
}

/// Hashable identity of one stored edge row.
struct EdgeKey: Hashable {
    let from: String
    let slot: String
    let to: String

    init(from: String, slot: String, to: String) {
        self.from = from; self.slot = slot; self.to = to
    }

    init(_ stored: StoredEdge) {
        self.init(from: stored.from, slot: stored.slot, to: stored.to)
    }
}

/// GraphStore backed by SwiftData. Each batch uses one ModelContext and one save, so it either
/// commits fully or is rolled back.
public actor SwiftDataGraphStore: GraphStore {
    private let container: ModelContainer

    /// File-backed store for the app.
    public init(url: URL) throws {
        container = try ModelContainer(for: StoredNode.self, StoredEdge.self,
                                       configurations: ModelConfiguration(url: url))
    }

    /// In-memory store for tests and previews.
    public init(inMemory: Bool) throws {
        container = try ModelContainer(for: StoredNode.self, StoredEdge.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func context() -> ModelContext {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        return ctx
    }

    public func read() throws -> GraphSnapshot {
        let ctx = context()
        var snap = GraphSnapshot()
        for n in try ctx.fetch(FetchDescriptor<StoredNode>()) {
            snap.nodes[n.id] = DynamicNode(id: n.id, className: n.className, props: Self.decode(n.propsJSON))
        }
        for e in try ctx.fetch(FetchDescriptor<StoredEdge>()) {
            snap.edges.insert(DynamicEdge(from: e.from, slot: e.slot, to: e.to))
        }
        return snap
    }

    public func apply(_ changes: [GraphChange]) throws {
        let ctx = context()
        do {
            // Load once per batch and work in memory: per-change fetches made 4k writes take ~28 s.
            var nodes = Dictionary(uniqueKeysWithValues: try ctx.fetch(FetchDescriptor<StoredNode>()).map { ($0.id, $0) })
            var edges = Set(try ctx.fetch(FetchDescriptor<StoredEdge>()).map(EdgeKey.init))
            for change in changes {
                try run(change, nodes: &nodes, edges: &edges, ctx: ctx)
            }
            try ctx.save()
        } catch {
            ctx.rollback()
            throw error
        }
    }

    private func run(_ change: GraphChange, nodes: inout [String: StoredNode], edges: inout Set<EdgeKey>,
                     ctx: ModelContext) throws {
        switch change {
        case .upsert(let n):
            let json = Self.encode(n.props)
            if let existing = nodes[n.id] {
                existing.className = n.className
                existing.propsJSON = json
            } else {
                let stored = StoredNode(id: n.id, className: n.className, propsJSON: json)
                ctx.insert(stored)
                nodes[n.id] = stored
            }

        case .remove(let id):
            if let existing = nodes.removeValue(forKey: id) { ctx.delete(existing) }
            for key in edges where key.from == id || key.to == id {
                edges.remove(key)
                try deleteEdge(key, ctx: ctx)
            }

        case .link(let e):
            // Reject dangling links here rather than trusting the caller.
            guard nodes[e.from] != nil, nodes[e.to] != nil else {
                throw SwiftDataGraphStoreError.missingEndpoint(from: e.from, to: e.to)
            }
            let key = EdgeKey(from: e.from, slot: e.slot, to: e.to)
            if !edges.contains(key) {
                ctx.insert(StoredEdge(from: e.from, slot: e.slot, to: e.to))
                edges.insert(key)
            }

        case .unlink(let e):
            let key = EdgeKey(from: e.from, slot: e.slot, to: e.to)
            if edges.remove(key) != nil { try deleteEdge(key, ctx: ctx) }
        }
    }

    /// Edge rows are fetched by their full key, so only the matching row is deleted.
    private func deleteEdge(_ key: EdgeKey, ctx: ModelContext) throws {
        let from = key.from, slot = key.slot, to = key.to
        for stored in try ctx.fetch(FetchDescriptor<StoredEdge>(predicate: #Predicate {
            $0.from == from && $0.slot == slot && $0.to == to
        })) {
            ctx.delete(stored)
        }
    }

    // MARK: JSON

    private static func encode(_ props: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(props) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ text: String) -> [String: JSONValue] {
        guard let data = text.data(using: .utf8),
              let props = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return props
    }
}
