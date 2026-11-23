import Foundation

// Purpose: the reply parsers of the `cer` steps (the parse stage of each step calls these). Each parser takes the
// model's text and returns the values the step needs, or the reason they are not usable. The JSON object is found by
// position (first `{` to last `}`), so prose around the JSON is ignored.
// - classify: `{"intent": <one of the six values>, "reason": ...}`.
// - extract: `{"args": {...}}`. The flattened form (arguments beside "tool" or with no "args") is also accepted, since
//   a small model sometimes writes it that way. A missing required argument is reported in `missing`, not rejected.
//
// Testing: `CERTests` (parse stage) covers each shape, the flattened form, missing and invalid arguments.

nonisolated struct CERClassifyOutput: Sendable, Equatable {
    let intent: CERIntent
    let reason: String
}

nonisolated struct CERClassifyReply: Decodable, Sendable {
    let intent: String
    let reason: String?
}

nonisolated struct CERSayReply: Decodable, Sendable {
    let say: String
}

nonisolated enum CERParse {
    /// Decodes the first JSON object in `text`. Returns a short reason when there is none or it does not fit.
    static func object<T: Decodable>(_ text: String, as type: T.Type) -> Checked<T> {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return .rejected("the reply has no JSON object")
        }
        do {
            return .ok(try JSONDecoder().decode(T.self, from: Data(text[start...end].utf8)))
        } catch {
            return .rejected("the JSON does not match the expected shape")
        }
    }

    /// Reply `{"intent","reason"}`. The intent must be one of the six values (four tools, chat, unclear).
    static func classify(_ text: String) -> Checked<CERClassifyOutput> {
        switch object(text, as: CERClassifyReply.self) {
        case .rejected(let why): return .rejected(why)
        case .ok(let reply):
            guard let intent = CERIntent(rawValue: reply.intent) else {
                return .rejected("intent must be one of record_note, record_event, retrieve_notes, retrieve_events, chat, unclear")
            }
            return .ok(CERClassifyOutput(intent: intent, reason: TokenBudget.clip(reply.reason ?? "", 200)))
        }
    }

    /// Reply `{"args": {...}}` (or flattened) for the intent's one tool. Required arguments that are absent or blank come
    /// back in `missing` with no call; present arguments that are invalid are rejected for the repair.
    static func extract(_ text: String, intent: CERIntent) -> Checked<CERExtraction> {
        guard let tool = CERToolbox.tool(for: intent) else {
            return .rejected("a \(intent.rawValue) message takes no tool")
        }
        let reply: [String: JSONValue]
        switch object(text, as: [String: JSONValue].self) {
        case .rejected(let why): return .rejected(why)
        case .ok(let value): reply = value
        }
        let args = arguments(of: reply)
        let missing = tool.requiredArgs.filter { ToolArgs.isBlank(args, $0) }
        if !missing.isEmpty {
            return .ok(CERExtraction(calls: [], missing: missing))
        }
        if let problem = tool.problem(args) { return .rejected(problem) }
        return .ok(CERExtraction(calls: [CERCall(tool: tool.name, args: args)], missing: []))
    }

    /// The arguments of a reply: the `args` object when there is one, otherwise every key except the envelope's own.
    private static func arguments(of reply: [String: JSONValue]) -> [String: JSONValue] {
        if case .object(let nested)? = reply["args"] { return nested }
        return reply.filter { $0.key != "args" && $0.key != "missing" && $0.key != "tool" }
    }

    /// Reply `{"say": "..."}`, or plain prose with no braces (accepted as the text itself).
    static func say(_ text: String) -> Checked<String> {
        if text.contains("{") {
            switch object(text, as: CERSayReply.self) {
            case .rejected(let why): return .rejected(why)
            case .ok(let reply):
                let say = reply.say.trimmingCharacters(in: .whitespacesAndNewlines)
                return say.isEmpty ? .rejected("the reply is empty") : .ok(say)
            }
        }
        let say = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return say.isEmpty ? .rejected("the reply is empty") : .ok(say)
    }
}
