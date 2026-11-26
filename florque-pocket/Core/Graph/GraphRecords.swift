import Foundation

// Purpose: value copies of the graph models, the drafts the settings screen saves, and the changeset that lets one
// turn's writes be undone. SwiftData objects never leave `PocketStore`; callers only see these.
//
// Testing: exercised by `GraphStoreTests` (writes, undo, type editing) and `GraphValidatorTests` (validation).

/// A copy of a `NodeType`.
public nonisolated struct NodeTypeRecord: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let typeDescription: String
    public let enabled: Bool
    public let onDeviceOnly: Bool
    public let schedulesReminder: Bool
    public let isDefault: Bool
    public let sortOrder: Int

    init(_ t: NodeType) {
        key = t.key; name = t.name; typeDescription = t.typeDescription; enabled = t.enabled
        onDeviceOnly = t.onDeviceOnly; schedulesReminder = t.schedulesReminder; isDefault = t.isDefault
        sortOrder = t.sortOrder
    }
}

/// A copy of an `EdgeType`.
public nonisolated struct EdgeTypeRecord: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let inverseName: String
    public let typeDescription: String
    public let fromNodeKeys: [String]
    public let toNodeKeys: [String]
    public let symmetric: Bool
    public let enabled: Bool
    public let isDefault: Bool
    public let sortOrder: Int

    init(_ t: EdgeType) {
        key = t.key; name = t.name; inverseName = t.inverseName; typeDescription = t.typeDescription
        fromNodeKeys = t.fromNodeKeys; toNodeKeys = t.toNodeKeys; symmetric = t.symmetric; enabled = t.enabled
        isDefault = t.isDefault; sortOrder = t.sortOrder
    }
}

/// A copy of a `Node`.
public nonisolated struct NodeRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let typeKey: String
    public let title: String
    public let body: String
    public let aliases: [String]
    public let dueAt: Date?
    public let status: String
    public let source: String
    public let eventId: String?
    public let createdAt: Date
    public let updatedAt: Date

    init(_ n: Node) {
        id = n.id; typeKey = n.typeKey; title = n.title; body = n.body; aliases = n.aliases; dueAt = n.dueAt
        status = n.status; source = n.source; eventId = n.eventId; createdAt = n.createdAt; updatedAt = n.updatedAt
    }
}

/// A copy of an `Edge`.
public nonisolated struct EdgeRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let typeKey: String
    public let fromId: UUID
    public let toId: UUID
    public let status: String
    public let source: String
    public let createdAt: Date

    init(_ e: Edge) {
        id = e.id; typeKey = e.typeKey; fromId = e.fromId; toId = e.toId; status = e.status; source = e.source
        createdAt = e.createdAt
    }
}

/// What the settings screen sends to create or edit a node type. `key` is nil when creating.
public nonisolated struct NodeTypeDraft: Sendable, Equatable {
    public var key: String?
    public var name: String
    public var typeDescription: String
    public var onDeviceOnly: Bool
    public var schedulesReminder: Bool
    public var enabled: Bool

    public init(key: String? = nil, name: String, typeDescription: String, onDeviceOnly: Bool = false,
                schedulesReminder: Bool = false, enabled: Bool = true) {
        self.key = key; self.name = name; self.typeDescription = typeDescription; self.onDeviceOnly = onDeviceOnly
        self.schedulesReminder = schedulesReminder; self.enabled = enabled
    }
}

/// What the settings screen sends to create or edit an edge type. `key` is nil when creating.
public nonisolated struct EdgeTypeDraft: Sendable, Equatable {
    public var key: String?
    public var name: String
    public var inverseName: String
    public var typeDescription: String
    public var fromNodeKeys: [String]
    public var toNodeKeys: [String]
    public var symmetric: Bool
    public var enabled: Bool

    public init(key: String? = nil, name: String, inverseName: String, typeDescription: String,
                fromNodeKeys: [String] = [], toNodeKeys: [String] = [], symmetric: Bool = false, enabled: Bool = true) {
        self.key = key; self.name = name; self.inverseName = inverseName; self.typeDescription = typeDescription
        self.fromNodeKeys = fromNodeKeys; self.toNodeKeys = toNodeKeys; self.symmetric = symmetric; self.enabled = enabled
    }
}

/// Everything one batch wrote, with enough detail to reverse it: created ids, and the previous values of nodes it
/// changed.
public nonisolated struct GraphChangeset: Sendable, Equatable {
    public var createdNodeIds: [UUID]
    public var createdEdgeIds: [UUID]
    public var previousNodes: [NodeRecord]
    /// Identifiers of reminders created for nodes in this change. Undo removes them from Reminders.
    public var reminderIds: [String] = []

    public static let empty = GraphChangeset(createdNodeIds: [], createdEdgeIds: [], previousNodes: [])

    public var isEmpty: Bool {
        createdNodeIds.isEmpty && createdEdgeIds.isEmpty && previousNodes.isEmpty && reminderIds.isEmpty
    }

    /// One changeset covering several writes, so a single undo reverses them all.
    public static func combined(_ sets: [GraphChangeset]) -> GraphChangeset? {
        guard !sets.isEmpty else { return nil }
        return GraphChangeset(createdNodeIds: sets.flatMap(\.createdNodeIds),
                              createdEdgeIds: sets.flatMap(\.createdEdgeIds),
                              previousNodes: sets.flatMap(\.previousNodes),
                              reminderIds: sets.flatMap(\.reminderIds))
    }
}

/// Errors from the graph store. Each one leaves the store unchanged.
public nonisolated enum GraphStoreError: Error, Equatable {
    case capReached(kind: String, limit: Int)
    case invalidName
    case keyTaken(String)
    case unknownNodeType(String)
    case unknownEdgeType(String)
    case unknownNode(UUID)
    case defaultTypeNotDeletable(String)
    case descriptionTooLong(limit: Int)
}
