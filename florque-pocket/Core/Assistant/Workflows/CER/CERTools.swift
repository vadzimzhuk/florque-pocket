import Foundation

// Purpose: the tools of the `cer` workflow. Four tools: record_note, record_event (write) and retrieve_notes,
// retrieve_events (read). The classifier picks one of them by name (see `CERIntent`), so the classify step holds all
// the classification logic; the extract step only fills that tool's arguments. Each tool names its required arguments,
// gives one example for the prompt, checks the arguments that are present, and runs against `PocketStore`.
//
// Testing: `CERToolTests` runs each tool on an in-memory store: required arguments, argument checks, writes, reads,
// limits, and the reminder for an event.

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
    /// The tool's name, which is also the classifier's value for it.
    var name: String { get }
    /// Arguments the turn cannot run without. A missing one is asked for in the clarify step.
    var requiredArgs: [String] { get }
    /// One catalog line, e.g. `record_note(body, title?): save a note`. Sent in the extract prompt.
    var catalogLine: String { get }
    /// One example of its arguments as JSON, sent in the extract prompt.
    var exampleArgs: String { get }
    /// Nil when the arguments that are present are usable; otherwise the reason, for the repair prompt.
    /// Missing required arguments are not checked here: the parser reports them as `missing`.
    func problem(_ args: [String: JSONValue]) -> String?
    func run(_ args: [String: JSONValue], _ context: CERToolContext) async throws -> CERToolResult
}

/// The classifier's values. A tool name means the message needs that tool; `chat` and `unclear` need none.
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
}

// MARK: - Write tools

nonisolated struct RecordNoteTool: CERTool {
    let name = "record_note"
    let requiredArgs = ["body"]
    let catalogLine = "record_note(body, title?): save a note"
    let exampleArgs = #"{"body":"wifi code 4411"}"#

    func problem(_ args: [String: JSONValue]) -> String? {
        nil
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
    let requiredArgs = ["title", "when"]
    let catalogLine = "record_event(title, when): add an event; when is an ISO local date-time"
    let exampleArgs = #"{"title":"Dentist","when":"2026-11-27T09:00:00"}"#

    func problem(_ args: [String: JSONValue]) -> String? {
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
    let requiredArgs: [String] = []
    let catalogLine = "retrieve_notes(query?, limit?): find saved notes by words"
    let exampleArgs = #"{"query":"wifi"}"#

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
    let requiredArgs: [String] = []
    let catalogLine = "retrieve_events(query?, from?, to?, limit?): find events, optionally between two ISO date-times"
    let exampleArgs = #"{"from":"2026-11-27T00:00:00","to":"2026-11-27T23:59:59"}"#

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

    /// The tool a classifier value names. Nil for `chat` and `unclear`.
    static func tool(for intent: CERIntent) -> (any CERTool)? {
        intent.needsTool ? tool(named: intent.rawValue) : nil
    }
}
