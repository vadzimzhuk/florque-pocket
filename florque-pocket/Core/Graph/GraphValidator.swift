import Foundation

// Purpose: the code that decides what the model's proposed nodes and edges may do (brief section 8). It is pure:
// it reads a snapshot of the graph and returns what to create, what to update and what to reject with a reason.
// The model never writes; the store applies the result. A rejected item is dropped alone, and the rest of the
// batch goes through.
//
// Testing: `GraphValidatorTests` covers each rule in section 8 and entity resolution (match by title, alias, id).

public nonisolated struct ProposedNode: Sendable, Equatable {
    /// The model's local name for this node, used by edges in the same batch.
    public var ref: String
    public var typeKey: String
    public var title: String
    public var body: String
    public var aliases: [String]
    /// The model's ISO local date-time, or nil when no time was stated.
    public var dueRaw: String?
    /// An existing node the model says this one is. Ignored unless it exists and has the same type.
    public var matchId: UUID?

    public init(ref: String, typeKey: String, title: String, body: String = "", aliases: [String] = [],
                dueRaw: String? = nil, matchId: UUID? = nil) {
        self.ref = ref; self.typeKey = typeKey; self.title = title; self.body = body; self.aliases = aliases
        self.dueRaw = dueRaw; self.matchId = matchId
    }
}

public nonisolated struct ProposedEdge: Sendable, Equatable {
    public var typeKey: String
    /// A `ref` from this batch, or the id of an existing node.
    public var from: String
    public var to: String

    public init(typeKey: String, from: String, to: String) {
        self.typeKey = typeKey; self.from = from; self.to = to
    }
}

/// What the graph looked like when the batch was validated.
public nonisolated struct GraphSnapshot: Sendable, Equatable {
    public var nodeTypes: [NodeTypeRecord]
    public var edgeTypes: [EdgeTypeRecord]
    public var nodes: [NodeRecord]
    public var edges: [EdgeRecord]

    public init(nodeTypes: [NodeTypeRecord], edgeTypes: [EdgeTypeRecord], nodes: [NodeRecord], edges: [EdgeRecord]) {
        self.nodeTypes = nodeTypes; self.edgeTypes = edgeTypes; self.nodes = nodes; self.edges = edges
    }
}

public nonisolated struct NewNode: Sendable, Equatable {
    public let id: UUID
    public let typeKey: String
    public let title: String
    public let body: String
    public let aliases: [String]
    public let dueAt: Date?
}

/// An existing node the batch refers to again: new aliases and, if there is one, text to add to the body.
public nonisolated struct NodeUpdate: Sendable, Equatable {
    public let id: UUID
    public let addAliases: [String]
    /// The body after the update, or nil when it does not change.
    public let body: String?
}

public nonisolated struct NewEdge: Sendable, Equatable {
    public let id: UUID
    public let typeKey: String
    public let fromId: UUID
    public let toId: UUID
}

public nonisolated enum GraphRejectionReason: Sendable, Equatable {
    case unknownType(String)
    case disabledType(String)
    case emptyTitle
    case titleTooLong(limit: Int)
    case bodyTooLong(limit: Int)
    case dueUnparseable(String)
    case dueTooOld
    case missingEndpoint(String)
    case selfLoop
    case endpointNotAllowed(String)
    case duplicateEdge
}

public nonisolated struct GraphRejection: Sendable, Equatable {
    /// The item's ref, or "from → to" for an edge.
    public let item: String
    public let reason: GraphRejectionReason
}

public nonisolated struct ValidatedGraphBatch: Sendable, Equatable {
    public var creates: [NewNode] = []
    public var updates: [NodeUpdate] = []
    public var edges: [NewEdge] = []
    public var rejections: [GraphRejection] = []

    public var isEmpty: Bool { creates.isEmpty && updates.isEmpty && edges.isEmpty }
}

public nonisolated enum GraphValidator {
    public static let maxTitleLength = 120
    public static let maxBodyLength = 1000
    /// Reminder types whose time is more than this far in the past are rejected.
    public static let maxPastDue: TimeInterval = 24 * 60 * 60

    /// Validates a batch against a snapshot. `makeId` supplies ids for new nodes and edges (tests pass a counter).
    public static func validate(nodes proposedNodes: [ProposedNode], edges proposedEdges: [ProposedEdge] = [],
                                against snapshot: GraphSnapshot, now: Date, timeZone: TimeZone = .current,
                                makeId: () -> UUID = { UUID() }) -> ValidatedGraphBatch {
        var batch = ValidatedGraphBatch()
        let nodeTypes = Dictionary(uniqueKeysWithValues: snapshot.nodeTypes.map { ($0.key, $0) })
        let edgeTypes = Dictionary(uniqueKeysWithValues: snapshot.edgeTypes.map { ($0.key, $0) })
        let nodesById = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        var resolvedRefs: [String: UUID] = [:]        // ref -> id, for creates and matches in this batch
        var batchTypeOf: [UUID: String] = [:]         // id -> type key, for every node the batch touches
        var batchCreates: [UUID: Int] = [:]           // created id -> index in creates
        var updateIndex: [UUID: Int] = [:]            // matched id -> index in updates

        // MARK: nodes
        for proposed in proposedNodes {
            let item = proposed.ref
            guard let type = nodeTypes[proposed.typeKey] else {
                batch.rejections.append(.init(item: item, reason: .unknownType(proposed.typeKey))); continue
            }
            guard type.enabled else {
                batch.rejections.append(.init(item: item, reason: .disabledType(proposed.typeKey))); continue
            }
            let title = proposed.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { batch.rejections.append(.init(item: item, reason: .emptyTitle)); continue }
            guard title.count <= maxTitleLength else {
                batch.rejections.append(.init(item: item, reason: .titleTooLong(limit: maxTitleLength))); continue
            }
            let body = proposed.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count <= maxBodyLength else {
                batch.rejections.append(.init(item: item, reason: .bodyTooLong(limit: maxBodyLength))); continue
            }
            var due: Date?
            if let raw = proposed.dueRaw, !raw.isEmpty {
                guard let parsed = DateParsing.parse(raw, in: timeZone) else {
                    batch.rejections.append(.init(item: item, reason: .dueUnparseable(raw))); continue
                }
                if type.schedulesReminder, parsed < now.addingTimeInterval(-maxPastDue) {
                    batch.rejections.append(.init(item: item, reason: .dueTooOld)); continue
                }
                due = parsed
            }
            let aliases = proposed.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= maxTitleLength }

            // Entity resolution: a valid matchId, then an existing node of the same type by title or alias.
            let existing: NodeRecord? = {
                if let id = proposed.matchId, let node = nodesById[id], node.typeKey == proposed.typeKey { return node }
                let key = normalize(title)
                return snapshot.nodes.first { node in
                    node.typeKey == proposed.typeKey
                        && ([node.title] + node.aliases).contains { normalize($0) == key }
                }
            }()
            if let existing {
                resolvedRefs[item] = existing.id
                batchTypeOf[existing.id] = existing.typeKey
                let known = Set(([existing.title] + existing.aliases).map(normalize))
                let newAliases = ([title] + aliases).filter { !known.contains(normalize($0)) }
                let mergedBody: String? = {
                    guard !body.isEmpty, !existing.body.contains(body) else { return nil }
                    let merged = existing.body.isEmpty ? body : existing.body + "\n" + body
                    return merged.count <= maxBodyLength ? merged : nil
                }()
                if newAliases.isEmpty, mergedBody == nil { continue }
                if let index = updateIndex[existing.id] {
                    let prior = batch.updates[index]
                    batch.updates[index] = NodeUpdate(id: existing.id, addAliases: prior.addAliases + newAliases,
                                                      body: mergedBody ?? prior.body)
                } else {
                    updateIndex[existing.id] = batch.updates.count
                    batch.updates.append(NodeUpdate(id: existing.id, addAliases: newAliases, body: mergedBody))
                }
                continue
            }
            // Same node proposed twice in one batch: the second ref points at the first.
            let key = normalize(title)
            if let sameInBatch = batchCreates.first(where: { _, index in
                let c = batch.creates[index]
                return c.typeKey == proposed.typeKey && normalize(c.title) == key
            }) {
                resolvedRefs[item] = sameInBatch.key
                continue
            }
            let id = makeId()
            batchCreates[id] = batch.creates.count
            batch.creates.append(NewNode(id: id, typeKey: proposed.typeKey, title: title, body: body,
                                         aliases: aliases, dueAt: due))
            resolvedRefs[item] = id
            batchTypeOf[id] = proposed.typeKey
        }

        // The model's proposal may also name an existing id directly.
        func endpoint(_ text: String) -> (UUID, String)? {
            if let id = resolvedRefs[text] ?? UUID(uuidString: text) {
                if let type = batchTypeOf[id] { return (id, type) }
                if let node = nodesById[id] { return (id, node.typeKey) }
            }
            return nil
        }

        // MARK: edges
        var seenEdges: [(type: String, from: UUID, to: UUID)] = snapshot.edges.map { ($0.typeKey, $0.fromId, $0.toId) }
        for proposed in proposedEdges {
            let item = "\(proposed.from) → \(proposed.to)"
            guard let type = edgeTypes[proposed.typeKey] else {
                batch.rejections.append(.init(item: item, reason: .unknownType(proposed.typeKey))); continue
            }
            guard type.enabled else {
                batch.rejections.append(.init(item: item, reason: .disabledType(proposed.typeKey))); continue
            }
            guard let (fromId, fromType) = endpoint(proposed.from) else {
                batch.rejections.append(.init(item: item, reason: .missingEndpoint(proposed.from))); continue
            }
            guard let (toId, toType) = endpoint(proposed.to) else {
                batch.rejections.append(.init(item: item, reason: .missingEndpoint(proposed.to))); continue
            }
            guard fromId != toId else { batch.rejections.append(.init(item: item, reason: .selfLoop)); continue }
            if !type.fromNodeKeys.isEmpty, !type.fromNodeKeys.contains(fromType) {
                batch.rejections.append(.init(item: item, reason: .endpointNotAllowed(fromType))); continue
            }
            if !type.toNodeKeys.isEmpty, !type.toNodeKeys.contains(toType) {
                batch.rejections.append(.init(item: item, reason: .endpointNotAllowed(toType))); continue
            }
            let duplicate = seenEdges.contains { edge in
                guard edge.type == type.key else { return false }
                let same = edge.from == fromId && edge.to == toId
                let reversed = edge.from == toId && edge.to == fromId
                return same || (type.symmetric && reversed)
            }
            guard !duplicate else { batch.rejections.append(.init(item: item, reason: .duplicateEdge)); continue }
            let id = makeId()
            batch.edges.append(NewEdge(id: id, typeKey: type.key, fromId: fromId, toId: toId))
            seenEdges.append((type.key, fromId, toId))
        }
        return batch
    }

    /// Case, diacritics and whitespace folded, so "Anná  Smith" and "anna smith" compare equal.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
