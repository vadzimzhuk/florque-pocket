import Foundation

/// What happened to one model reply.
public struct ToolOutcome: Sendable, Equatable {
    /// The reply's `say` text, to show the user.
    public var say: String
    /// Reasons the batch was rejected. Empty when it was applied.
    public var issues: [String]
    /// True when the write batch was committed (or there were no writes).
    public var committed: Bool
    /// Results of read tools (`recall`, `due`) as JSON objects.
    public var results: [JSONValue]
    /// Ids of nodes created or changed by this batch.
    public var changedIds: [String]
}

struct ToolReply: Decodable {
    let calls: [ToolCall]?
    let say: String?
}

struct ToolCall: Decodable {
    let tool: String
    let args: [String: JSONValue]?
}

/// Parses a model reply and applies its tool calls to the graph.
/// The model never writes directly: a batch is validated against the ontology and
/// applied as one change set, or rejected with reasons and nothing is written.
public struct ToolExecutor: Sendable {
    public let ontology: Ontology
    public let store: any GraphStore
    public var maxCalls = 5

    public init(ontology: Ontology, store: any GraphStore) {
        self.ontology = ontology
        self.store = store
    }

    public func run(reply: String, now: Date = .now) async -> ToolOutcome {
        let timestamp = ISO8601DateFormatter().string(from: now)
        guard let parsed = Self.parseReply(reply) else {
            return ToolOutcome(say: "", issues: ["reply is not a JSON object with calls"], committed: false, results: [], changedIds: [])
        }
        // A JSON object with neither calls nor say is not a tool reply: reject it so repair and escalation run.
        if parsed.calls == nil, parsed.say == nil {
            return ToolOutcome(say: "", issues: ["reply has neither calls nor say"], committed: false, results: [], changedIds: [])
        }
        let calls = parsed.calls ?? []
        if calls.count > maxCalls {
            return ToolOutcome(say: parsed.say ?? "", issues: ["too many calls: \(calls.count) > \(maxCalls)"],
                               committed: false, results: [], changedIds: [])
        }
        let snapshot: GraphSnapshot
        do { snapshot = try await store.read() } catch {
            return ToolOutcome(say: parsed.say ?? "", issues: ["could not read the graph: \(error)"],
                               committed: false, results: [], changedIds: [])
        }

        var batch = Batch(ontology: ontology, snapshot: snapshot, timestamp: timestamp)
        for (index, call) in calls.enumerated() {
            batch.run(call, label: "call \(index + 1) (\(call.tool))")
        }

        if !batch.issues.isEmpty {
            return ToolOutcome(say: parsed.say ?? "", issues: batch.issues, committed: false,
                               results: batch.results, changedIds: [])
        }
        do {
            if !batch.changes.isEmpty { try await store.apply(batch.changes) }
        } catch {
            return ToolOutcome(say: parsed.say ?? "", issues: ["write failed: \(error)"], committed: false,
                               results: [], changedIds: [])
        }
        return ToolOutcome(say: parsed.say ?? "", issues: [], committed: true,
                           results: batch.results, changedIds: batch.changedIds.sorted())
    }

    /// Accepts a reply even when the model wraps the JSON in prose or code fences.
    static func parseReply(_ text: String) -> ToolReply? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        let json = String(text[start...end])
        return try? JSONDecoder().decode(ToolReply.self, from: Data(json.utf8))
    }
}

/// Working state for one batch. Calls see earlier calls' effects.
private struct Batch {
    let ontology: Ontology
    var snapshot: GraphSnapshot
    let timestamp: String
    var changes: [GraphChange] = []
    var issues: [String] = []
    var results: [JSONValue] = []
    var changedIds: Set<String> = []

    init(ontology: Ontology, snapshot: GraphSnapshot, timestamp: String) {
        self.ontology = ontology
        self.snapshot = snapshot
        self.timestamp = timestamp
    }

    mutating func run(_ call: ToolCall, label: String) {
        let args = call.args ?? [:]
        switch call.tool {
        case "remember": remember(args, label: label)
        case "link": link(args, label: label, remove: false)
        case "unlink": link(args, label: label, remove: true)
        case "set_status": setStatus(args, label: label)
        case "recall": recall(args)
        case "due": due(args)
        default: issues.append("\(label): unknown tool \(call.tool)")
        }
    }

    // MARK: writes

    mutating func remember(_ args: [String: JSONValue], label: String) {
        guard let type = args["type"]?.stringValue else {
            issues.append("\(label): remember needs a type"); return
        }
        guard let cls = ontology.classDef(type) else {
            issues.append("\(label): unknown type \(type)"); return
        }
        let existing = args["id"]?.stringValue.flatMap { snapshot.nodes[$0] }
        if let existing, existing.className != type {
            issues.append("\(label): \(existing.id) is a \(existing.className), not \(type)"); return
        }
        let id = args["id"]?.stringValue ?? UUID().uuidString.lowercased()

        var fields: [String: JSONValue] = [:]
        var links: [String: JSONValue] = [:]
        for (key, value) in args where key != "type" && key != "id" {
            if cls.slots[key]?.isEdge == true { links[key] = value } else { fields[key] = value }
        }
        if existing == nil {
            if fields["status"] == nil { fields["status"] = .string("proposed") }
            fields["created_at"] = fields["created_at"] ?? .string(timestamp)
        }
        fields["updated_at"] = .string(timestamp)

        let check = Validator.checkNode(ontology, className: type, props: fields, partial: existing != nil)
        issues += check.issues.map { "\(label): \($0)" }
        if !check.issues.isEmpty { return }

        let merged = (existing?.props ?? [:]).merging(check.props) { _, new in new }
        let node = DynamicNode(id: id, className: type, props: merged)
        put(node)

        for (slot, value) in links.sorted(by: { $0.key < $1.key }) {
            replaceLinks(from: id, fromClass: type, slot: slot, value: value, label: label)
        }
        changedIds.insert(id)
    }

    /// Replaces every link on one slot with the given ids.
    mutating func replaceLinks(from id: String, fromClass: String, slot: String, value: JSONValue, label: String) {
        let targets = ids(from: value)
        guard let targets else { issues.append("\(label): \(slot) needs an id or list of ids"); return }
        let old = snapshot.edges.filter { $0.from == id && $0.slot == slot }
        for edge in old { drop(edge) }
        for target in targets {
            guard let toNode = snapshot.nodes[target] else {
                issues.append("\(label): no node with id \(target)"); continue
            }
            let problems = Validator.checkLink(ontology, fromClass: fromClass, slot: slot, toClass: toNode.className)
            issues += problems.map { "\(label): \($0)" }
            if problems.isEmpty { add(DynamicEdge(from: id, slot: slot, to: target)) }
        }
    }

    mutating func link(_ args: [String: JSONValue], label: String, remove: Bool) {
        guard let from = args["from"]?.stringValue, let slot = args["link"]?.stringValue,
              let to = args["to"]?.stringValue else {
            issues.append("\(label): needs from, link and to"); return
        }
        let edge = DynamicEdge(from: from, slot: slot, to: to)
        if remove {
            if snapshot.edges.contains(edge) { drop(edge) }
            else { issues.append("\(label): no link \(slot) from \(from) to \(to)") }
            return
        }
        guard let fromNode = snapshot.nodes[from], let toNode = snapshot.nodes[to] else {
            issues.append("\(label): unknown id"); return
        }
        let problems = Validator.checkLink(ontology, fromClass: fromNode.className, slot: slot, toClass: toNode.className)
        if !problems.isEmpty { issues += problems.map { "\(label): \($0)" }; return }
        add(edge)
        changedIds.insert(from)
    }

    mutating func setStatus(_ args: [String: JSONValue], label: String) {
        guard let id = args["id"]?.stringValue, let node = snapshot.nodes[id] else {
            issues.append("\(label): unknown id"); return
        }
        let check = Validator.checkNode(ontology, className: node.className,
                                        props: ["status": args["status"] ?? .null], partial: true)
        issues += check.issues.map { "\(label): \($0)" }
        guard check.issues.isEmpty, let status = check.props["status"] else { return }
        var updated = node
        updated.props["status"] = status
        updated.props["updated_at"] = .string(timestamp)
        put(updated)
        changedIds.insert(id)
    }

    // MARK: reads

    mutating func recall(_ args: [String: JSONValue]) {
        let type = args["type"]?.stringValue
        let text = args["text"]?.stringValue?.lowercased()
        var limit = 10
        if case .number(let n)? = args["limit"] { limit = Int(n) }
        let hits = snapshot.nodes.values
            .filter { $0.status != "dropped" }
            .filter { type == nil || ontology.isA($0.className, type!) }
            .filter { node in
                guard let text else { return true }
                return node.props.values.contains { ($0.stringValue ?? "").lowercased().contains(text) }
            }
            .sorted { ($0.props["updated_at"]?.stringValue ?? "") > ($1.props["updated_at"]?.stringValue ?? "") }
            .prefix(limit)
        results += hits.map(Self.summary)
    }

    mutating func due(_ args: [String: JSONValue]) {
        guard let before = args["before"]?.stringValue else {
            issues.append("due needs before"); return
        }
        let hits = snapshot.nodes.values
            .filter { $0.className == "Task" && ["proposed", "active"].contains($0.status) }
            .filter { ($0.props["due"]?.stringValue ?? "~") <= before && $0.props["due"] != nil }
            .sorted { ($0.props["due"]?.stringValue ?? "") < ($1.props["due"]?.stringValue ?? "") }
        results += hits.map(Self.summary)
    }

    // MARK: helpers

    private static func summary(_ n: DynamicNode) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(n.id), "type": .string(n.className), "title": .string(n.title), "status": .string(n.status)]
        if let due = n.props["due"] { o["due"] = due }
        return .object(o)
    }

    private func ids(from value: JSONValue) -> [String]? {
        if let s = value.stringValue { return [s] }
        if let a = value.arrayValue {
            let strings = a.compactMap(\.stringValue)
            return strings.count == a.count ? strings : nil
        }
        return nil
    }

    private mutating func put(_ node: DynamicNode) {
        snapshot.nodes[node.id] = node
        changes.append(.upsert(node))
        changedIds.insert(node.id)
    }

    private mutating func add(_ edge: DynamicEdge) {
        snapshot.edges.insert(edge)
        changes.append(.link(edge))
    }

    private mutating func drop(_ edge: DynamicEdge) {
        snapshot.edges.remove(edge)
        changes.append(.unlink(edge))
    }
}
