import Foundation

// Purpose: the tools of the `cer` workflow. Four tools: record_note, record_event (write) and retrieve_notes,
// retrieve_events (read). Each tool checks its own arguments, runs against `PocketStore`, and reports a short result.
// The toolbox lists the tools per intent, so an extract prompt only names the tools that intent may use.
//
// Testing: `CERToolTests` runs each tool on an in-memory store: argument checks, writes, reads, limits, and the
// reminder for an event.

/// A tool call the model asked for: name and arguments, already checked by the parser.
nonisolated struct CERCall: Sendable, Equatable {
    let tool: String
    let args: [String: JSONValue]
}

/// One item in a tool result: what the respond step may mention.
nonisolated struct CERItem: Sendable, Equatable {
    let id: String
    let title: String
    /// Local date-time for events, nil for notes.
    let when: String?
}

/// What one tool run produced. `summary` is a single short line (≤160 characters).
nonisolated struct CERToolResult: Sendable, Equatable {
    let tool: String
    let items: [CERItem]
    let summary: String
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
    var name: String { get }
    /// `record` for write tools, `retrieve` for read tools.
    var intent: CERIntent { get }
    /// One catalog line, e.g. `record_note(body, title?): save a note the user shared`. Sent in every extract prompt.
    var catalogLine: String { get }
    /// Nil when the arguments are usable; otherwise the reason, for the repair prompt.
    func problem(_ args: [String: JSONValue]) -> String?
    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult
}

/// The intents of a turn. Only `record` and `retrieve` use tools; `chat` and `unclear` do not.
nonisolated enum CERIntent: String, Sendable, Equatable, CaseIterable {
    case record, retrieve, chat, unclear
}

// MARK: - Argument helpers

nonisolated enum ToolArgs {
    static func text(_ args: [String: JSONValue], _ key: String) -> String? {
        args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
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
}

// MARK: - Write tools

nonisolated struct RecordNoteTool: CERTool {
    let name = "record_note"
    let intent = CERIntent.record
    let catalogLine = "record_note(body, title?): save a note the user shared"

    func problem(_ args: [String: JSONValue]) -> String? {
        if (ToolArgs.text(args, "body") ?? "").isEmpty { return "record_note needs a body" }
        return nil
    }

    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult {
        let body = ToolArgs.text(args, "body") ?? ""
        let title = ToolArgs.text(args, "title").flatMap { $0.isEmpty ? nil : $0 } ?? TokenBudget.clip(body, 60)
        let id = UUID().uuidString.lowercased()
        try await context.store.saveNote(id: id, title: title, body: body, now: context.now)
        return CERToolResult(tool: name, items: [CERItem(id: id, title: title, when: nil)],
                             summary: "Saved note: \(title)")
    }
}

nonisolated struct RecordEventTool: CERTool {
    let name = "record_event"
    let intent = CERIntent.record
    let catalogLine = "record_event(title, when): add an event with its date and time (when is required)"

    func problem(_ args: [String: JSONValue]) -> String? {
        if (ToolArgs.text(args, "title") ?? "").isEmpty { return "record_event needs a title" }
        if args["when"] == nil { return "record_event needs when" }
        if case .failure(let why) = ToolArgs.date(args, "when", .current) { return why.message }
        return nil
    }

    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult {
        let title = ToolArgs.text(args, "title") ?? ""
        guard let when = try ToolArgs.optionalDate(args, "when", context.timeZone) else {
            throw CERToolError(message: "record_event needs when")
        }
        let id = UUID().uuidString.lowercased()
        try await context.store.addTasks([NewTask(id: id, title: title, due: when, about: nil)], now: context.now)
        if let reminders = context.reminders {
            let eventId = try await reminders.createReminder(title: title, due: when)
            try await context.store.setEventId(eventId, taskId: id)
        }
        let whenText = DateParsing.formatLocal(when, in: context.timeZone)
        return CERToolResult(tool: name, items: [CERItem(id: id, title: title, when: whenText)],
                             summary: "Added event: \(title) at \(whenText)")
    }
}

// MARK: - Read tools

nonisolated struct RetrieveNotesTool: CERTool {
    let name = "retrieve_notes"
    let intent = CERIntent.retrieve
    let catalogLine = "retrieve_notes(query?, limit?): find saved notes by words"

    func problem(_ args: [String: JSONValue]) -> String? {
        guard let value = args["limit"] else { return nil }
        if case .number = value { return nil }
        return "limit must be a number"
    }

    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult {
        let found = try await context.store.search(text: ToolArgs.text(args, "query"), kind: .note,
                                                   limit: ToolArgs.limit(args))
        let items = found.map { CERItem(id: $0.id, title: $0.title, when: nil) }
        let summary = items.isEmpty ? "No notes found." : "Found \(items.count) note(s)."
        return CERToolResult(tool: name, items: items, summary: summary)
    }
}

nonisolated struct RetrieveEventsTool: CERTool {
    let name = "retrieve_events"
    let intent = CERIntent.retrieve
    let catalogLine = "retrieve_events(query?, from?, to?, limit?): find events, optionally between two ISO date-times"

    func problem(_ args: [String: JSONValue]) -> String? {
        for key in ["from", "to"] {
            if case .failure(let why) = ToolArgs.date(args, key, .current) { return why.message }
        }
        return nil
    }

    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult {
        let from = try ToolArgs.optionalDate(args, "from", context.timeZone)
        let to = try ToolArgs.optionalDate(args, "to", context.timeZone)
        let events = try await context.store.events(text: ToolArgs.text(args, "query"), from: from, to: to,
                                                    limit: ToolArgs.limit(args))
        let items = events.map { CERItem(id: $0.id, title: $0.title, when: $0.due.map { DateParsing.formatLocal($0, in: context.timeZone) }) }
        let summary = items.isEmpty ? "No events found." : "Found \(items.count) event(s)."
        return CERToolResult(tool: name, items: items, summary: summary)
    }
}

// MARK: - Toolbox

nonisolated enum CERToolbox {
    static let all: [any CERTool] = [RecordNoteTool(), RecordEventTool(), RetrieveNotesTool(), RetrieveEventsTool()]

    static func tool(named name: String) -> (any CERTool)? {
        all.first { $0.name == name }
    }

    /// The tools one intent may call. `chat` and `unclear` have none.
    static func tools(for intent: CERIntent) -> [any CERTool] {
        all.filter { $0.intent == intent }
    }

    /// The catalog lines for one intent, as the extract prompt lists them.
    static func catalog(for intent: CERIntent) -> String {
        tools(for: intent).map { "- \($0.catalogLine)" }.joined(separator: "\n")
    }
}
