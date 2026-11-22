import Foundation

// Purpose: turns one model reply into store changes. The model never writes directly. It can create a Task
// (`remember`), search saved items (`recall`) and list tasks due by a time (`due`). A reply is parsed, every call
// is checked, and the creates are applied in one store save. If any call is rejected, nothing is written and the
// reasons go back to the model in the repair prompt.
//
// Testing: `ToolExecutorTests` (in PocketStoreTests.swift) covers valid replies, each rejection reason, the
// allow-lists, and that a rejected batch leaves the store unchanged. `StepEvalTests` checks the reply shape per step.

/// What happened to one model reply.
public struct ToolOutcome: Sendable, Equatable {
    /// The reply's `say` text, to show the user.
    public var say: String
    /// Reasons the batch was rejected. Empty when it was applied.
    public var issues: [String]
    /// True when the batch was applied (or there was nothing to write).
    public var committed: Bool
    /// Results of the read tools (`recall`, `due`), each a JSON object.
    public var results: [JSONValue]
    /// Ids of tasks created by this batch.
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

/// A tool helper's result: the checked value, or the reason it was rejected (shown to the model in the repair step).
enum Checked<Value> {
    case ok(Value)
    case rejected(String)
}

/// Why a reply was rejected before any call ran. `message` is what `ToolOutcome.issues` holds.
struct ReplyProblem: Error, Equatable {
    let message: String
}

public struct ToolExecutor: Sendable {
    let store: PocketStore
    /// Local time zone for `due` values that carry no zone.
    let timeZone: TimeZone
    var maxCalls = 5
    /// When set, only these tools may be called in this step (for example `["recall", "due"]` for an answer step).
    var allowedTools: Set<String>?
    /// When set, `remember` may only create items of these types (for example `["Task"]`).
    var allowedTypes: Set<String>?

    init(store: PocketStore, timeZone: TimeZone, allowedTools: Set<String>? = nil, allowedTypes: Set<String>? = nil) {
        self.store = store
        self.timeZone = timeZone
        self.allowedTools = allowedTools
        self.allowedTypes = allowedTypes
    }

    /// Reasons a call is outside this step's allow-list. Empty when every call is allowed.
    func stageIssues(_ calls: [ToolCall]) -> [String] {
        var issues: [String] = []
        for (index, call) in calls.enumerated() {
            let label = "call \(index + 1) (\(call.tool))"
            if let allowedTools, !allowedTools.contains(call.tool) {
                issues.append("\(label): tool not allowed in this step")
            }
            if call.tool == "remember", let allowedTypes {
                let type = call.args?["type"]?.stringValue ?? ""
                if !allowedTypes.contains(type) { issues.append("\(label): type \(type) not allowed in this step") }
            }
        }
        return issues
    }

    public func run(reply: String, now: Date = .now) async -> ToolOutcome {
        let parsed: ToolReply
        switch Self.parseReply(reply) {
        case .success(let value):
            parsed = value
        case .failure(let problem):
            // The reason goes back to the model in the repair prompt, so it says what was wrong.
            return ToolOutcome(say: "", issues: [problem.message], committed: false, results: [], changedIds: [])
        }
        // A JSON object with neither calls nor say is not a tool reply: reject it so repair and escalation run.
        if parsed.calls == nil, parsed.say == nil {
            return ToolOutcome(say: "", issues: ["reply has neither calls nor say"], committed: false, results: [], changedIds: [])
        }
        let calls = parsed.calls ?? []
        let say = parsed.say ?? ""
        let stage = stageIssues(calls)
        if !stage.isEmpty {
            return ToolOutcome(say: say, issues: stage, committed: false, results: [], changedIds: [])
        }
        if calls.count > maxCalls {
            return ToolOutcome(say: say, issues: ["too many calls: \(calls.count) > \(maxCalls)"],
                               committed: false, results: [], changedIds: [])
        }

        var issues: [String] = []
        var creates: [NewTask] = []
        var results: [JSONValue] = []
        for (index, call) in calls.enumerated() {
            let label = "call \(index + 1) (\(call.tool))"
            let args = call.args ?? [:]
            do {
                switch call.tool {
                case "remember":
                    switch try await planTask(args, now: now) {
                    case .ok(let task): creates.append(task)
                    case .rejected(let why): issues.append("\(label): \(why)")
                    }
                case "recall":
                    switch try await recall(args) {
                    case .ok(let found): results += found
                    case .rejected(let why): issues.append("\(label): \(why)")
                    }
                case "due":
                    switch try await due(args) {
                    case .ok(let found): results += found
                    case .rejected(let why): issues.append("\(label): \(why)")
                    }
                default:
                    issues.append("\(label): unknown tool \(call.tool)")
                }
            } catch {
                issues.append("\(label): could not read the store: \(error)")
            }
        }
        if !issues.isEmpty {
            return ToolOutcome(say: say, issues: issues, committed: false, results: results, changedIds: [])
        }
        do {
            if !creates.isEmpty { try await store.addTasks(creates, now: now) }
        } catch {
            return ToolOutcome(say: say, issues: ["write failed: \(error)"], committed: false, results: [], changedIds: [])
        }
        return ToolOutcome(say: say, issues: [], committed: true, results: results, changedIds: creates.map(\.id))
    }

    // MARK: tools

    /// `remember`: checks one Task. Only tasks can be created here; notes are saved by the workflow, not the model.
    private func planTask(_ args: [String: JSONValue], now: Date) async throws -> Checked<NewTask> {
        guard args["id"] == nil else { return .rejected("remember creates new items; leave out id") }
        guard let type = args["type"]?.stringValue else { return .rejected("remember needs a type") }
        guard type == ItemKind.task.rawValue else { return .rejected("type must be Task, not \(type)") }
        guard let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return .rejected("Task needs a title")
        }
        var due: Date?
        if let value = args["due"] {
            guard let text = value.stringValue, let parsed = DateParsing.parse(text, in: timeZone) else {
                return .rejected("due must be an ISO local date-time, e.g. 2026-11-27T09:00:00")
            }
            due = parsed
        }
        var about: String?
        if let value = args["about"] {
            guard let id = value.stringValue, try await store.note(id: id) != nil else {
                return .rejected("about must be the id of a saved note")
            }
            about = id
        }
        return .ok(NewTask(id: UUID().uuidString.lowercased(), title: title, due: due, about: about))
    }

    /// `recall`: finds active items by text, optionally of one type. The results are returned to the model.
    private func recall(_ args: [String: JSONValue]) async throws -> Checked<[JSONValue]> {
        var kind: ItemKind?
        if let type = args["type"]?.stringValue {
            guard let parsed = ItemKind(rawValue: type) else { return .rejected("type must be Note or Task") }
            kind = parsed
        }
        var limit = 10
        if case .number(let n)? = args["limit"] { limit = min(max(Int(n), 1), 50) }
        let text = args["text"]?.stringValue
        let found = try await store.search(text: text, kind: kind, limit: limit)
        return .ok(found.map { Self.summary($0, timeZone: timeZone) })
    }

    /// `due`: lists active tasks due at or before a time.
    private func due(_ args: [String: JSONValue]) async throws -> Checked<[JSONValue]> {
        guard let text = args["before"]?.stringValue else { return .rejected("due needs before") }
        guard let before = DateParsing.parse(text, in: timeZone) else {
            return .rejected("before must be an ISO local date-time")
        }
        let tasks = try await store.dueTasks(before: before)
        return .ok(tasks.map { Self.summary(.task($0), timeZone: timeZone) })
    }

    // MARK: helpers

    /// The JSON a read tool returns for one item.
    static func summary(_ item: StoredItem, timeZone: TimeZone) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id), "type": .string(item.kind.rawValue),
            "title": .string(item.title),
        ]
        switch item {
        case .note(let n): object["status"] = .string(n.status.rawValue)
        case .task(let t):
            object["status"] = .string(t.status.rawValue)
            if let due = t.due { object["due"] = .string(DateParsing.formatLocal(due, in: timeZone)) }
        }
        return .object(object)
    }

    /// Accepts a reply even when the model wraps the JSON in prose or code fences.
    /// A failure carries the reason, so the repair step can tell the model what to fix.
    static func parseReply(_ text: String) -> Result<ToolReply, ReplyProblem> {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return .failure(ReplyProblem(message: "reply has no JSON object"))
        }
        let json = Data(String(text[start...end]).utf8)
        do {
            return .success(try JSONDecoder().decode(ToolReply.self, from: json))
        } catch {
            // Syntax errors are reported by JSONSerialization with the position; decoding errors name the field.
            do {
                _ = try JSONSerialization.jsonObject(with: json)
            } catch let syntax as NSError {
                let detail = syntax.userInfo[NSDebugDescriptionErrorKey] as? String ?? "invalid JSON"
                return .failure(ReplyProblem(message: "reply is not valid JSON: \(detail)"))
            } catch {}
            return .failure(ReplyProblem(message: "reply does not match the tool contract: \(error)"))
        }
    }
}
