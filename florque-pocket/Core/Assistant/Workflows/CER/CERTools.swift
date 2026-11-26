import Foundation

// Purpose: the tools of the `cer` workflow. Two tools: `record` (writes nodes and links through the graph validator
// and store) and `retrieve` (reads nodes, with one-hop neighbours). The classifier still names one of its values
// (record_note, record_event, retrieve_notes, retrieve_events); `CERToolbox.tool(for:)` maps each to the tool that
// does the work, so the type of a node comes from the extraction, not from the classifier. Each tool names its
// required arguments, gives one example for the prompt, checks the arguments that are present, and runs against `PocketStore`.
//
// Testing: `CERToolTests` runs both tools on an in-memory store: required arguments, argument checks, writes, reads,
// limits, reminders for reminder types, and the changeset that undo uses.

/// A tool call the model asked for: name and arguments, already checked by the parser.
nonisolated struct CERCall: Sendable, Equatable {
    let tool: String
    let args: [String: JSONValue]
}

/// One item in a tool result: what the respond step may mention.
nonisolated struct CERItem: Sendable, Equatable {
    let id: String
    let title: String
    /// Local date-time when the node has a due time, nil otherwise.
    let when: String?
}

/// What one tool run produced. `summary` is a single short line (≤160 characters). `changeset` is set by a tool that
/// wrote something, so the turn can be undone.
nonisolated struct CERToolResult: Sendable, Equatable {
    let tool: String
    let items: [CERItem]
    let summary: String
    var changeset: GraphChangeset? = nil
}

/// A tool failed at run time (for example the store rejected the write). The message goes to the clarify step.
nonisolated struct CERToolError: Error, Equatable {
    let message: String
}

/// What a tool may use when it runs.
nonisolated struct CERToolContext: Sendable {
    let store: PocketStore
    let timeZone: TimeZone
    let now: Date
    let reminders: (any RemindersAdapter)?
}

nonisolated protocol CERTool: Sendable {
    /// The tool's name, which is also the name the call carries.
    var name: String { get }
    /// Arguments the turn cannot run without. A missing one is asked for in the clarify step.
    var requiredArgs: [String] { get }
    /// One catalog line, sent in the extract prompt.
    var catalogLine: String { get }
    /// One example of its arguments as JSON, sent in the extract prompt.
    var exampleArgs: String { get }
    /// Nil when the arguments that are present are usable; otherwise the reason, for the repair prompt.
    /// Missing required arguments are not checked here: the parser reports them as `missing`.
    func problem(_ args: [String: JSONValue]) -> String?
    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult
}

/// The classifier's values. A value names what the message needs; `chat` and `unclear` need no tool.
nonisolated enum CERIntent: String, Sendable, Equatable, CaseIterable {
    case recordNote = "record_note"
    case recordEvent = "record_event"
    case retrieveNotes = "retrieve_notes"
    case retrieveEvents = "retrieve_events"
    case chat
    case unclear

    /// True when the message needs a tool (extract then fills its arguments).
    var needsTool: Bool {
        self != .chat && self != .unclear
    }
}

// MARK: - Argument helpers

nonisolated enum ToolArgs {
    static func text(_ args: [String: JSONValue], _ key: String) -> String? {
        args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the argument is absent, null, or an empty string.
    static func isBlank(_ args: [String: JSONValue], _ key: String) -> Bool {
        switch args[key] {
        case nil, .null?: return true
        case .string(let s)?: return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    /// At most 5 results, at least 1. Missing or non-numeric values use `value`.
    static func limit(_ args: [String: JSONValue], default value: Int = 5) -> Int {
        guard case .number(let n)? = args["limit"] else { return value }
        return min(max(Int(n), 1), 5)
    }

    /// Nil when absent. A present value must be an ISO local date-time.
    static func date(_ args: [String: JSONValue], _ key: String, _ timeZone: TimeZone) -> Result<Date?, CERToolError> {
        guard let value = args[key] else { return .success(nil) }
        guard let text = value.stringValue, let date = DateParsing.parse(text, in: timeZone) else {
            return .failure(CERToolError(message: "\(key) must be an ISO local date-time, e.g. 2026-11-27T09:00:00"))
        }
        return .success(date)
    }

    /// Like `date`, for use in a throwing run.
    static func optionalDate(_ args: [String: JSONValue], _ key: String, _ timeZone: TimeZone) throws -> Date? {
        try date(args, key, timeZone).get()
    }

    /// The objects in an array argument. Anything else is ignored.
    static func objects(_ value: JSONValue?) -> [[String: JSONValue]] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item in
            if case .object(let object) = item { return object }
            return nil
        }
    }

    /// The strings in an array argument.
    static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }
}

// MARK: - record

nonisolated struct RecordTool: CERTool {
    let name = "record"
    let requiredArgs = ["nodes"]
    let catalogLine = """
        record(nodes, edges?): save what the user shared. nodes: [{"ref","type","title","body"?,"aliases"?,"dueAt"?}] \
        with type from the node types below; edges: [{"type","from","to"}] where from and to are refs or ids, type from the link types below. \
        dueAt is an ISO local date-time only when the user gave one.
        """
    let exampleArgs = #"{"nodes":[{"ref":"anna","type":"person","title":"Anna"},{"ref":"interview","type":"event","title":"Interview","dueAt":"2026-11-27T10:00:00"}],"edges":[{"type":"participates","from":"anna","to":"interview"}]}"#

    func problem(_ args: [String: JSONValue]) -> String? {
        if let nodes = args["nodes"], case .array = nodes {} else { return "nodes must be a list of objects" }
        if let edges = args["edges"], case .array = edges {} else if args["edges"] != nil {
            return "edges must be a list of objects"
        }
        return nil
    }

    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult {
        let nodeObjects = ToolArgs.objects(args["nodes"])
        let edgeObjects = ToolArgs.objects(args["edges"])
        let proposedNodes = nodeObjects.enumerated().map { index, object -> ProposedNode in
            let due = ToolArgs.text(object, "dueAt")
            return ProposedNode(
                ref: ToolArgs.text(object, "ref") ?? "n\(index + 1)",
                typeKey: ToolArgs.text(object, "type") ?? "note",
                title: ToolArgs.text(object, "title") ?? "",
                body: ToolArgs.text(object, "body") ?? "",
                aliases: ToolArgs.strings(object["aliases"]),
                dueRaw: due?.isEmpty == false ? due : nil,
                matchId: ToolArgs.text(object, "matchId").flatMap(UUID.init(uuidString:)))
        }
        let proposedEdges = edgeObjects.map { object in
            ProposedEdge(typeKey: ToolArgs.text(object, "type") ?? "", from: ToolArgs.text(object, "from") ?? "",
                         to: ToolArgs.text(object, "to") ?? "")
        }

        let snapshot = try await context.store.snapshot()
        let batch = GraphValidator.validate(nodes: proposedNodes, edges: proposedEdges, against: snapshot,
                                            now: context.now, timeZone: context.timeZone)
        var changeset = try await context.store.apply(batch, now: context.now)

        // Reminders: a node whose type schedules one and that has a due time gets an Apple Reminder.
        let reminderTypes = Set(snapshot.nodeTypes.filter(\.schedulesReminder).map(\.key))
        var reminderFailures: [String] = []
        for node in batch.creates where reminderTypes.contains(node.typeKey) {
            guard let due = node.dueAt, let reminders = context.reminders else { continue }
            do {
                let eventId = try await reminders.createReminder(title: node.title, due: due)
                try await context.store.setNodeEventId(eventId, nodeId: node.id)
                changeset.reminderIds.append(eventId)
            } catch {
                reminderFailures.append(node.title)
            }
        }

        let titles = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0.title) })
        var items = batch.creates.map { node in
            CERItem(id: node.id.uuidString.lowercased(), title: node.title,
                    when: node.dueAt.map { DateParsing.formatLocal($0, in: context.timeZone) })
        }
        items += batch.updates.compactMap { update in
            titles[update.id].map { CERItem(id: update.id.uuidString.lowercased(), title: $0, when: nil) }
        }

        var parts: [String] = []
        if !items.isEmpty {
            let saved = items.map { item in item.when.map { "\(item.title) at \($0)" } ?? item.title }
            parts.append("Saved: " + saved.joined(separator: ", "))
        }
        let untimed = batch.creates.filter { reminderTypes.contains($0.typeKey) && $0.dueAt == nil }.map(\.title)
        if !untimed.isEmpty { parts.append("No time given for \(untimed.joined(separator: ", "))") }
        if !reminderFailures.isEmpty { parts.append("Reminder not created for \(reminderFailures.joined(separator: ", "))") }
        if !batch.rejections.isEmpty {
            parts.append("Not saved: " + batch.rejections.map(Self.describe).joined(separator: "; "))
        }
        if parts.isEmpty { parts.append("Nothing to remember.") }
        return CERToolResult(tool: name, items: items, summary: TokenBudget.clip(parts.joined(separator: ". "), 160),
                             changeset: changeset.isEmpty ? nil : changeset)
    }

    /// One short reason per rejected item, for the respond step.
    static func describe(_ rejection: GraphRejection) -> String {
        let item = rejection.item
        switch rejection.reason {
        case .unknownType(let key): return "\(item) has an unknown type \(key)"
        case .disabledType(let key): return "\(key) is turned off"
        case .emptyTitle: return "\(item) has no title"
        case .titleTooLong: return "\(item) has a title that is too long"
        case .bodyTooLong: return "\(item) has too much text"
        case .dueUnparseable: return "\(item) has an unclear time"
        case .dueTooOld: return "\(item) is in the past"
        case .missingEndpoint(let ref): return "a link to \(ref) has nothing to attach to"
        case .selfLoop: return "a link points to itself"
        case .endpointNotAllowed(let type): return "a link cannot start or end at \(type)"
        case .duplicateEdge: return "that link already exists"
        }
    }
}

// MARK: - retrieve

nonisolated struct RetrieveTool: CERTool {
    let name = "retrieve"
    let requiredArgs: [String] = []
    let catalogLine = "retrieve(query?, type?, from?, to?, limit?): find remembered items by words, a node type key, or a due-time range"
    let exampleArgs = #"{"query":"wifi"}"#

    func problem(_ args: [String: JSONValue]) -> String? {
        if let value = args["limit"] {
            guard case .number = value else { return "limit must be a number" }
        }
        for key in ["from", "to"] {
            if case .failure(let why) = ToolArgs.date(args, key, .current) { return why.message }
        }
        return nil
    }

    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult {
        let from = try ToolArgs.optionalDate(args, "from", context.timeZone)
        let to = try ToolArgs.optionalDate(args, "to", context.timeZone)
        let typeKey = ToolArgs.text(args, "type").flatMap { $0.isEmpty ? nil : $0 }
        let found = try await context.store.searchNodes(text: ToolArgs.text(args, "query"), typeKey: typeKey,
                                                        from: from, to: to, limit: ToolArgs.limit(args))
        var nodes = found
        // One hop: the strongest linked node of each of the top three, unless it is already listed.
        for node in found.prefix(3) {
            if let neighbour = try await context.store.strongestNeighbour(of: node.id),
               !nodes.contains(where: { $0.id == neighbour.id }) {
                nodes.append(neighbour)
            }
        }
        let items = nodes.map { node in
            CERItem(id: node.id.uuidString.lowercased(), title: node.title,
                    when: node.dueAt.map { DateParsing.formatLocal($0, in: context.timeZone) })
        }
        let summary = found.isEmpty ? "No matching items found." : "Found \(found.count) item(s)."
        return CERToolResult(tool: name, items: items, summary: summary)
    }
}

// MARK: - Toolbox

nonisolated enum CERToolbox {
    static let all: [any CERTool] = [RecordTool(), RetrieveTool()]

    static func tool(named name: String) -> (any CERTool)? {
        all.first { $0.name == name }
    }

    /// The tool a classifier value needs. Nil for `chat` and `unclear`.
    static func tool(for intent: CERIntent) -> (any CERTool)? {
        switch intent {
        case .recordNote, .recordEvent: RecordTool()
        case .retrieveNotes, .retrieveEvents: RetrieveTool()
        case .chat, .unclear: nil
        }
    }
}
