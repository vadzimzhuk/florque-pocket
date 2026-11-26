import Foundation
import SwiftData

// Purpose: the generic memory graph. A `Node` is an entity (note, event, person, ...) and an `Edge` is a
// relationship between two nodes. What a node or edge means is set by its type: a `NodeType` or `EdgeType` with a
// user-editable key, name and "when to use" description that goes into the extraction prompt. Models are flat and
// id-based (no SwiftData relationships), every property has a default, and no unique constraints are used, so
// CloudKit sync stays possible later.
//
// Testing: `GraphSeedTests` checks the defaults and that seeding is idempotent.

/// A kind of node the user can remember, e.g. "person". `typeDescription` says when Pocket should use it.
@Model
public final class NodeType {
    public var key: String = ""
    public var name: String = ""
    public var typeDescription: String = ""
    public var enabled: Bool = true
    /// Never included in any cloud payload.
    public var onDeviceOnly: Bool = false
    /// Nodes of this type with a valid `dueAt` schedule a local reminder.
    public var schedulesReminder: Bool = false
    public var isDefault: Bool = false
    public var sortOrder: Int = 0

    public init(key: String, name: String, typeDescription: String, enabled: Bool = true, onDeviceOnly: Bool = false,
                schedulesReminder: Bool = false, isDefault: Bool = false, sortOrder: Int = 0) {
        self.key = key
        self.name = name
        self.typeDescription = typeDescription
        self.enabled = enabled
        self.onDeviceOnly = onDeviceOnly
        self.schedulesReminder = schedulesReminder
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }
}

/// An entity the user talked about. `typeKey` names its `NodeType`.
@Model
public final class Node {
    public var id: UUID = UUID()
    public var typeKey: String = "note"
    public var title: String = ""
    public var body: String = ""
    public var aliases: [String] = []
    public var dueAt: Date?
    /// "accepted" | "proposed" | "archived"
    public var status: String = "accepted"
    /// "user" | "assistant"
    public var source: String = "user"
    /// Identifier of the Apple Reminders item created for this node, once it exists.
    public var eventId: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(id: UUID = UUID(), typeKey: String, title: String, body: String = "", aliases: [String] = [],
                dueAt: Date? = nil, status: String = "accepted", source: String = "user", eventId: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.typeKey = typeKey
        self.title = title
        self.body = body
        self.aliases = aliases
        self.dueAt = dueAt
        self.status = status
        self.source = source
        self.eventId = eventId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A kind of relationship, e.g. "participates" from a person to an event. `typeDescription` says when to use it.
@Model
public final class EdgeType {
    public var key: String = ""
    public var name: String = ""
    public var inverseName: String = ""
    public var typeDescription: String = ""
    /// Node type keys the edge may start from. Empty means any.
    public var fromNodeKeys: [String] = []
    /// Node type keys the edge may end at. Empty means any.
    public var toNodeKeys: [String] = []
    public var symmetric: Bool = false
    public var enabled: Bool = true
    public var isDefault: Bool = false
    public var sortOrder: Int = 0

    public init(key: String, name: String, inverseName: String, typeDescription: String, fromNodeKeys: [String] = [],
                toNodeKeys: [String] = [], symmetric: Bool = false, enabled: Bool = true, isDefault: Bool = false,
                sortOrder: Int = 0) {
        self.key = key
        self.name = name
        self.inverseName = inverseName
        self.typeDescription = typeDescription
        self.fromNodeKeys = fromNodeKeys
        self.toNodeKeys = toNodeKeys
        self.symmetric = symmetric
        self.enabled = enabled
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }
}

/// A relationship between two nodes, stored as ids only.
@Model
public final class Edge {
    public var id: UUID = UUID()
    public var typeKey: String = ""
    public var fromId: UUID = UUID()
    public var toId: UUID = UUID()
    /// "accepted" | "proposed"
    public var status: String = "accepted"
    /// "user" | "assistant"
    public var source: String = "user"
    public var createdAt: Date = Date()

    public init(id: UUID = UUID(), typeKey: String, fromId: UUID, toId: UUID, status: String = "accepted",
                source: String = "user", createdAt: Date = Date()) {
        self.id = id
        self.typeKey = typeKey
        self.fromId = fromId
        self.toId = toId
        self.status = status
        self.source = source
        self.createdAt = createdAt
    }
}
