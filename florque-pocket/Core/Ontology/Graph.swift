import Foundation

public struct DynamicNode: Sendable, Equatable {
    public var id: String
    public var className: String
    public var props: [String: JSONValue]

    public init(id: String, className: String, props: [String: JSONValue]) {
        self.id = id; self.className = className; self.props = props
    }

    public var title: String { props["title"]?.stringValue ?? "" }
    public var status: String { props["status"]?.stringValue ?? "" }
}

public struct DynamicEdge: Sendable, Hashable {
    public var from: String
    public var slot: String
    public var to: String

    public init(from: String, slot: String, to: String) { self.from = from; self.slot = slot; self.to = to }
}

public struct GraphSnapshot: Sendable, Equatable {
    public var nodes: [String: DynamicNode] = [:]
    public var edges: Set<DynamicEdge> = []

    public init() {}
}

/// One change inside an atomic batch.
public enum GraphChange: Sendable, Equatable {
    case upsert(DynamicNode)
    case remove(id: String)
    case link(DynamicEdge)
    case unlink(DynamicEdge)
}

/// Storage seam. The Ladybug backend implements `apply` as one transaction.
public protocol GraphStore: Sendable {
    func read() async throws -> GraphSnapshot
    func apply(_ changes: [GraphChange]) async throws
}

/// Simple store used by tests and until the Ladybug backend is wired in.
public actor InMemoryGraphStore: GraphStore {
    private var snapshot: GraphSnapshot

    public init(_ snapshot: GraphSnapshot = GraphSnapshot()) { self.snapshot = snapshot }

    public func read() -> GraphSnapshot { snapshot }

    public func apply(_ changes: [GraphChange]) throws {
        var next = snapshot
        for change in changes {
            switch change {
            case .upsert(let n): next.nodes[n.id] = n
            case .remove(let id):
                next.nodes[id] = nil
                next.edges = next.edges.filter { $0.from != id && $0.to != id }
            case .link(let e): next.edges.insert(e)
            case .unlink(let e): next.edges.remove(e)
            }
        }
        snapshot = next
    }
}
