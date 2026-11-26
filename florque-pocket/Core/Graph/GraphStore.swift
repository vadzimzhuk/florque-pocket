import Foundation
import SwiftData

// Purpose: the graph's reads and writes, kept on the same `PocketStore` actor as the old notes and tasks. It covers
// editing node and edge types (with caps and the reassignment rules from the brief), applying a validated batch
// with a changeset, undoing a changeset, and the one-time import of the old notes and tasks into nodes.
//
// Testing: `GraphStoreTests` covers type editing, caps, delete reassignment, apply, undo and the legacy import.

extension PocketStore {
    public static let legacyImportKey = "pocket.graph.legacyImported.v1"
    static let maxNameLength = 40

    // MARK: reads

    public func nodeTypes() throws -> [NodeTypeRecord] {
        try modelContext.fetch(FetchDescriptor<NodeType>()).map(NodeTypeRecord.init).sorted { $0.sortOrder < $1.sortOrder }
    }

    public func edgeTypes() throws -> [EdgeTypeRecord] {
        try modelContext.fetch(FetchDescriptor<EdgeType>()).map(EdgeTypeRecord.init).sorted { $0.sortOrder < $1.sortOrder }
    }

    public func nodes() throws -> [NodeRecord] {
        try modelContext.fetch(FetchDescriptor<Node>()).map(NodeRecord.init)
    }

    public func edges() throws -> [EdgeRecord] {
        try modelContext.fetch(FetchDescriptor<Edge>()).map(EdgeRecord.init)
    }

    public func node(id: UUID) throws -> NodeRecord? {
        try fetchNode(id).map(NodeRecord.init)
    }

    /// Every edge that starts or ends at `id`.
    public func edges(touching id: UUID) throws -> [EdgeRecord] {
        try modelContext.fetch(FetchDescriptor<Edge>())
            .filter { $0.fromId == id || $0.toId == id }
            .map(EdgeRecord.init)
    }

    public func snapshot() throws -> GraphSnapshot {
        GraphSnapshot(nodeTypes: try nodeTypes(), edgeTypes: try edgeTypes(), nodes: try nodes(), edges: try edges())
    }

    // MARK: node types

    /// Creates or edits a node type. Returns its key. Person and feeling stay on-device only.
    @discardableResult
    public func saveNodeType(_ draft: NodeTypeDraft) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draft.typeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maxNameLength else { throw GraphStoreError.invalidName }
        guard !description.isEmpty else { throw GraphStoreError.invalidName }
        guard description.count <= GraphDefaults.maxDescriptionLength else {
            throw GraphStoreError.descriptionTooLong(limit: GraphDefaults.maxDescriptionLength)
        }
        if let key = draft.key {
            guard let type = try fetchNodeType(key) else { throw GraphStoreError.unknownNodeType(key) }
            try commit {
                type.name = name
                type.typeDescription = description
                type.onDeviceOnly = Self.lockedOnDevice.contains(key) ? true : draft.onDeviceOnly
                type.schedulesReminder = draft.schedulesReminder
                type.enabled = draft.enabled
            }
            return key
        }
        let customCount = try modelContext.fetch(FetchDescriptor<NodeType>()).filter { !$0.isDefault }.count
        guard customCount < GraphDefaults.maxCustomNodeTypes else {
            throw GraphStoreError.capReached(kind: "node type", limit: GraphDefaults.maxCustomNodeTypes)
        }
        let key = Self.slug(name)
        guard !key.isEmpty else { throw GraphStoreError.invalidName }
        guard try fetchNodeType(key) == nil else { throw GraphStoreError.keyTaken(key) }
        let order = (try nodeTypes().map(\.sortOrder).max() ?? 0) + 1
        try commit {
            modelContext.insert(NodeType(key: key, name: name, typeDescription: description,
                                         enabled: draft.enabled, onDeviceOnly: draft.onDeviceOnly,
                                         schedulesReminder: draft.schedulesReminder, isDefault: false,
                                         sortOrder: order))
        }
        return key
    }

    public func setNodeTypeEnabled(key: String, enabled: Bool) throws {
        guard let type = try fetchNodeType(key) else { throw GraphStoreError.unknownNodeType(key) }
        try commit { type.enabled = enabled }
    }

    /// Deletes a custom node type. Its nodes move to `note`, and it is removed from edge endpoint lists.
    /// Default types cannot be deleted.
    public func deleteNodeType(key: String) throws {
        guard let type = try fetchNodeType(key) else { throw GraphStoreError.unknownNodeType(key) }
        guard !type.isDefault else { throw GraphStoreError.defaultTypeNotDeletable(key) }
        try commit {
            for node in try modelContext.fetch(FetchDescriptor<Node>()) where node.typeKey == key {
                node.typeKey = "note"
            }
            for edgeType in try modelContext.fetch(FetchDescriptor<EdgeType>()) {
                edgeType.fromNodeKeys.removeAll { $0 == key }
                edgeType.toNodeKeys.removeAll { $0 == key }
            }
            modelContext.delete(type)
        }
    }

    // MARK: edge types

    @discardableResult
    public func saveEdgeType(_ draft: EdgeTypeDraft) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let inverse = draft.inverseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = draft.typeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maxNameLength, !inverse.isEmpty else { throw GraphStoreError.invalidName }
        guard !description.isEmpty else { throw GraphStoreError.invalidName }
        guard description.count <= GraphDefaults.maxDescriptionLength else {
            throw GraphStoreError.descriptionTooLong(limit: GraphDefaults.maxDescriptionLength)
        }
        let known = Set(try modelContext.fetch(FetchDescriptor<NodeType>()).map(\.key))
        for key in draft.fromNodeKeys + draft.toNodeKeys where !known.contains(key) {
            throw GraphStoreError.unknownNodeType(key)
        }
        if let key = draft.key {
            guard let type = try fetchEdgeType(key) else { throw GraphStoreError.unknownEdgeType(key) }
            try commit {
                type.name = name
                type.inverseName = inverse
                type.typeDescription = description
                type.fromNodeKeys = draft.fromNodeKeys
                type.toNodeKeys = draft.toNodeKeys
                type.symmetric = draft.symmetric
                type.enabled = draft.enabled
            }
            return key
        }
        let customCount = try modelContext.fetch(FetchDescriptor<EdgeType>()).filter { !$0.isDefault }.count
        guard customCount < GraphDefaults.maxCustomEdgeTypes else {
            throw GraphStoreError.capReached(kind: "edge type", limit: GraphDefaults.maxCustomEdgeTypes)
        }
        let key = Self.slug(name)
        guard !key.isEmpty else { throw GraphStoreError.invalidName }
        guard try fetchEdgeType(key) == nil else { throw GraphStoreError.keyTaken(key) }
        let order = (try edgeTypes().map(\.sortOrder).max() ?? 0) + 1
        try commit {
            modelContext.insert(EdgeType(key: key, name: name, inverseName: inverse, typeDescription: description,
                                         fromNodeKeys: draft.fromNodeKeys, toNodeKeys: draft.toNodeKeys,
                                         symmetric: draft.symmetric, enabled: draft.enabled,
                                         isDefault: false, sortOrder: order))
        }
        return key
    }

    public func setEdgeTypeEnabled(key: String, enabled: Bool) throws {
        guard let type = try fetchEdgeType(key) else { throw GraphStoreError.unknownEdgeType(key) }
        try commit { type.enabled = enabled }
    }

    /// Deletes a custom edge type. Its edges move to `relates_to`. Default types cannot be deleted.
    public func deleteEdgeType(key: String) throws {
        guard let type = try fetchEdgeType(key) else { throw GraphStoreError.unknownEdgeType(key) }
        guard !type.isDefault else { throw GraphStoreError.defaultTypeNotDeletable(key) }
        try commit {
            for edge in try modelContext.fetch(FetchDescriptor<Edge>()) where edge.typeKey == key {
                edge.typeKey = "relates_to"
            }
            modelContext.delete(type)
        }
    }

    // MARK: graph writes

    /// Writes a validated batch in one save and returns what it changed, so the turn can be undone.
    public func apply(_ batch: ValidatedGraphBatch, now: Date) throws -> GraphChangeset {
        var changeset = GraphChangeset.empty
        try commit {
            for create in batch.creates {
                modelContext.insert(Node(id: create.id, typeKey: create.typeKey, title: create.title,
                                         body: create.body, aliases: create.aliases, dueAt: create.dueAt,
                                         status: "accepted", source: "assistant", createdAt: now, updatedAt: now))
                changeset.createdNodeIds.append(create.id)
            }
            for update in batch.updates {
                guard let node = try fetchNode(update.id) else { throw GraphStoreError.unknownNode(update.id) }
                changeset.previousNodes.append(NodeRecord(node))
                let known = Set(node.aliases)
                node.aliases += update.addAliases.filter { !known.contains($0) }
                if let body = update.body { node.body = body }
                node.updatedAt = now
            }
            for edge in batch.edges {
                modelContext.insert(Edge(id: edge.id, typeKey: edge.typeKey, fromId: edge.fromId, toId: edge.toId,
                                         status: "accepted", source: "assistant", createdAt: now))
                changeset.createdEdgeIds.append(edge.id)
            }
        }
        return changeset
    }

    /// Reverses a changeset: removes what it created (and any edge touching those nodes) and restores the
    /// previous values of the nodes it changed.
    public func undo(_ changeset: GraphChangeset) throws {
        try commit {
            let created = Set(changeset.createdNodeIds)
            let createdEdges = Set(changeset.createdEdgeIds)
            for edge in try modelContext.fetch(FetchDescriptor<Edge>())
            where createdEdges.contains(edge.id) || created.contains(edge.fromId) || created.contains(edge.toId) {
                modelContext.delete(edge)
            }
            for node in try modelContext.fetch(FetchDescriptor<Node>()) where created.contains(node.id) {
                modelContext.delete(node)
            }
            for prior in changeset.previousNodes {
                guard let node = try fetchNode(prior.id) else { continue }
                node.typeKey = prior.typeKey
                node.title = prior.title
                node.body = prior.body
                node.aliases = prior.aliases
                node.dueAt = prior.dueAt
                node.status = prior.status
                node.source = prior.source
                node.eventId = prior.eventId
                node.updatedAt = prior.updatedAt
            }
        }
    }

    // MARK: legacy import

    /// Copies the old notes and tasks into nodes, once. Notes become `note` nodes; tasks become `event` nodes when
    /// they have a due time and `task` nodes otherwise. A task that came from a note gets a `follows_up` edge.
    /// The old rows stay where they are, because the current conversation code still reads them. Returns the
    /// number of items copied, which is 0 after the first run.
    public func importLegacyIfNeeded(defaults: UserDefaults = .standard) throws -> Int {
        guard !defaults.bool(forKey: Self.legacyImportKey) else { return 0 }
        try seedGraphDefaults()
        let notes = try modelContext.fetch(FetchDescriptor<Note>())
        let tasks = try modelContext.fetch(FetchDescriptor<PocketTask>())
        var noteIds: [String: UUID] = [:]
        try commit {
            for note in notes {
                let id = UUID(uuidString: note.id) ?? UUID()
                noteIds[note.id] = id
                modelContext.insert(Node(id: id, typeKey: "note", title: note.title, body: note.body,
                                         status: note.status == .active ? "accepted" : "archived", source: "user",
                                         createdAt: note.createdAt, updatedAt: note.updatedAt))
            }
            for task in tasks {
                let id = UUID(uuidString: task.id) ?? UUID()
                modelContext.insert(Node(id: id, typeKey: task.due == nil ? "task" : "event", title: task.title,
                                         dueAt: task.due,
                                         status: task.status == .active ? "accepted" : "archived", source: "user",
                                         eventId: task.eventId, createdAt: task.createdAt, updatedAt: task.updatedAt))
                if let about = task.about, let noteId = noteIds[about] {
                    modelContext.insert(Edge(typeKey: "follows_up", fromId: id, toId: noteId, source: "user",
                                             createdAt: task.createdAt))
                }
            }
        }
        defaults.set(true, forKey: Self.legacyImportKey)
        return notes.count + tasks.count
    }

    // MARK: helpers

    /// Types the brief keeps on the device no matter what the user chooses.
    static let lockedOnDevice: Set<String> = ["person", "feeling"]

    /// A stable key from a name: lowercase ASCII letters and digits, with single underscores between words.
    static func slug(_ name: String) -> String {
        var out = ""
        for character in name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            if character.isASCII, character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty, out.last != "_" {
                out.append("_")
            }
        }
        while out.last == "_" { out.removeLast() }
        return out
    }

    private func fetchNode(_ id: UUID) throws -> Node? {
        try modelContext.fetch(FetchDescriptor<Node>(predicate: #Predicate { $0.id == id })).first
    }

    private func fetchNodeType(_ key: String) throws -> NodeType? {
        try modelContext.fetch(FetchDescriptor<NodeType>(predicate: #Predicate { $0.key == key })).first
    }

    private func fetchEdgeType(_ key: String) throws -> EdgeType? {
        try modelContext.fetch(FetchDescriptor<EdgeType>(predicate: #Predicate { $0.key == key })).first
    }
}
