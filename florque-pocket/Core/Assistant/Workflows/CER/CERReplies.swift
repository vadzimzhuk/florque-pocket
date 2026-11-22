import Foundation

// Purpose: the reply parsers of the `cer` steps (the parse stage of each step calls these). Each parser takes the
// model's text and returns the values the step needs, or the reason they are missing. The JSON object is found by
// position (first `{` to last `}`), so prose around the JSON is ignored.
//
// Testing: `CERTests` (parse stage) covers valid, invalid, invented-tool and missing-time replies.

nonisolated struct CERClassifyOutput: Sendable, Equatable {
    let intent: CERIntent
    let reason: String
}

nonisolated struct CERClassifyReply: Decodable, Sendable {
    let intent: String
    let reason: String?
}

nonisolated struct CERExtractCall: Decodable, Sendable {
    let tool: String
    let args: [String: JSONValue]?
}

nonisolated struct CERExtractReply: Decodable, Sendable {
    let calls: [CERExtractCall]?
    let missing: [String]?
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

    /// Reply `{"intent","reason"}`. The intent must be one of the four known values.
    static func classify(_ text: String) -> Checked<CERClassifyOutput> {
        switch object(text, as: CERClassifyReply.self) {
        case .rejected(let why): return .rejected(why)
        case .ok(let reply):
            guard let intent = CERIntent(rawValue: reply.intent) else {
                return .rejected("intent must be record, retrieve, chat or unclear")
            }
            return .ok(CERClassifyOutput(intent: intent, reason: TokenBudget.clip(reply.reason ?? "", 200)))
        }
    }

    /// Reply `{"calls","missing"}`. Checks the calls against the intent's tools. A `record_event` without `when` is not
    /// an error: it becomes "time" in `missing`, so the clarify step asks for it.
    static func extract(_ text: String, intent: CERIntent) -> Checked<CERExtraction> {
        let reply: CERExtractReply
        switch object(text, as: CERExtractReply.self) {
        case .rejected(let why): return .rejected(why)
        case .ok(let value): reply = value
        }
        var missing = reply.missing ?? []
        var calls: [CERCall] = []
        for raw in reply.calls ?? [] {
            let args = raw.args ?? [:]
            if raw.tool == RecordEventTool().name, args["when"] == nil {
                if !missing.contains("time") { missing.append("time") }
                continue
            }
            guard let tool = CERToolbox.tool(named: raw.tool), tool.intent == intent else {
                return .rejected("tool \(raw.tool) is not allowed for a \(intent.rawValue) message")
            }
            if let problem = tool.problem(args) { return .rejected(problem) }
            calls.append(CERCall(tool: raw.tool, args: args))
        }
        if calls.count > 3 { return .rejected("at most 3 tool calls") }
        switch intent {
        case .chat, .unclear:
            if !calls.isEmpty { return .rejected("a \(intent.rawValue) message takes no tool") }
        case .record, .retrieve:
            if calls.isEmpty && missing.isEmpty { return .rejected("no tool call for a \(intent.rawValue) message") }
        }
        return .ok(CERExtraction(calls: calls, missing: missing))
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
