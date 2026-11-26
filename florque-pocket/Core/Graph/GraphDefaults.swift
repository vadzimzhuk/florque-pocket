import Foundation

// Purpose: the default node and edge types seeded on first launch, and the limits on custom types. Seeding is by
// key and idempotent, so a launch never duplicates a default or overwrites the user's edits to one.
//
// Testing: `GraphSeedTests` seeds an in-memory store twice and checks the counts, the locked flags and the keys.

public nonisolated enum GraphDefaults {
    public static let maxCustomNodeTypes = 10
    public static let maxCustomEdgeTypes = 10
    public static let maxDescriptionLength = 80

    /// Default node types, in display order.
    public static let nodeTypes: [NodeTypeSpec] = [
        NodeTypeSpec(key: "note", name: "Note", typeDescription: "Anything worth remembering that fits nothing else",
                     onDeviceOnly: false, schedulesReminder: false, sortOrder: 0),
        NodeTypeSpec(key: "event", name: "Event", typeDescription: "Something happening at a specific time",
                     onDeviceOnly: false, schedulesReminder: true, sortOrder: 1),
        NodeTypeSpec(key: "task", name: "Task", typeDescription: "Something the user needs to do",
                     onDeviceOnly: false, schedulesReminder: true, sortOrder: 2),
        NodeTypeSpec(key: "person", name: "Person", typeDescription: "Someone in the user's life, mentioned by name",
                     onDeviceOnly: true, schedulesReminder: false, sortOrder: 3),
        NodeTypeSpec(key: "feeling", name: "Feeling",
                     typeDescription: "How the user says they feel, in their own words",
                     onDeviceOnly: true, schedulesReminder: false, sortOrder: 4),
    ]

    /// Default edge types, in display order.
    public static let edgeTypes: [EdgeTypeSpec] = [
        EdgeTypeSpec(key: "relates_to", name: "Related", inverseName: "Related",
                     typeDescription: "Two things that are connected in a way no other link describes",
                     symmetric: true, sortOrder: 0),
        EdgeTypeSpec(key: "participates", name: "Participates", inverseName: "Has participant",
                     typeDescription: "A person takes part in an event",
                     fromNodeKeys: ["person"], toNodeKeys: ["event"], sortOrder: 1),
        EdgeTypeSpec(key: "requires", name: "Requires", inverseName: "Required by",
                     typeDescription: "A task or event needs something else to happen first",
                     fromNodeKeys: ["task", "event"], sortOrder: 2),
        EdgeTypeSpec(key: "mentions", name: "Mentions", inverseName: "Mentioned in",
                     typeDescription: "A note refers to a person, event or other node by name",
                     sortOrder: 3),
        EdgeTypeSpec(key: "part_of", name: "Part of", inverseName: "Contains",
                     typeDescription: "A node is a piece of a larger node", sortOrder: 4),
        EdgeTypeSpec(key: "follows_up", name: "Follows up", inverseName: "Followed up by",
                     typeDescription: "A node continues or follows up on an earlier node", sortOrder: 5),
    ]

    public nonisolated struct NodeTypeSpec: Sendable, Equatable {
        public let key: String
        public let name: String
        public let typeDescription: String
        public let onDeviceOnly: Bool
        public let schedulesReminder: Bool
        public let sortOrder: Int
    }

    public nonisolated struct EdgeTypeSpec: Sendable, Equatable {
        public let key: String
        public let name: String
        public let inverseName: String
        public let typeDescription: String
        public var fromNodeKeys: [String] = []
        public var toNodeKeys: [String] = []
        public var symmetric: Bool = false
        public let sortOrder: Int
    }
}
