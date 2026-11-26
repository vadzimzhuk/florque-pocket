import Foundation

// Purpose: the state of one `cer` turn. It is a plain value: each step reads it through its input gatekeeper and
// changes it only through its own reducer (see `Steps/CERStepKind.swift`). `log` records every stage of every step,
// and `rejections` records every refusal (by a gate or a reducer), so a bad step never changes the state silently.
//
// Testing: `CERTests` checks each step's gate and reducer on states built here, and the whole turns through `Assistant`.

/// The steps of the `cer` graph. The raw value is the node name.
nonisolated enum CERStep: String, Sendable, CaseIterable {
    case classify, classifyRepair, extract, extractRepair, execute, respond, respondRepair, clarify
}

/// The node and link type lists the record tool may use, as prompt lines (see `GraphPromptBlocks`).
nonisolated struct CERTypeBlocks: Sendable, Equatable {
    let nodes: String
    let edges: String
}

/// A checked extraction: tool calls to run, and the arguments the user still has to give (for example "when").
nonisolated struct CERExtraction: Sendable, Equatable {
    let calls: [CERCall]
    let missing: [String]
}

nonisolated struct CERState: Sendable {
    let text: String
    let history: [String]
    let policy: RoutePolicy
    let now: Date
    let noteId: String
    let timeZone: TimeZone

    var intent: CERIntent?
    var reason = ""
    var classifyAttempts = 0
    var extractAttempts = 0
    var extraction: CERExtraction?
    var executed = false
    var results: [CERToolResult] = []
    /// The enabled node and link types for this turn, built from the store before the classify step runs.
    var typeBlocks: CERTypeBlocks?
    var toolError: String?
    var respondAttempts = 0
    var say = ""
    var question: String?
    /// Why the last model reply or tool run was rejected. Goes into the repair prompt.
    var problem = ""
    /// Every stage of every step, in order, including refusals.
    var log: [CERLogEntry] = []
    /// Refusals recorded by gates and reducers, as "step: reason".
    var rejections: [String] = []

    var missing: [String] { extraction?.missing ?? [] }

    init(text: String, history: [String], policy: RoutePolicy, now: Date, noteId: String, timeZone: TimeZone) {
        self.text = text
        self.history = history
        self.policy = policy
        self.now = now
        self.noteId = noteId
        self.timeZone = timeZone
    }

    /// The results as the respond prompt sees them, for the budget check.
    var resultsText: String {
        results.map { "\($0.tool): \($0.summary) \($0.items.map(\.title).joined(separator: ", "))" }.joined(separator: "\n")
    }

    /// True when the turn cannot continue without asking the user: no intent, an unclear intent, missing details,
    /// a tool error, or a step that gave up after its retries.
    var needsQuestion: Bool {
        intent == nil || intent == .unclear || !missing.isEmpty || toolError != nil
            || classifyAttempts >= 2 || extractAttempts >= 2
    }

    /// The state unchanged, with a refusal recorded. Reducers use this when an outcome breaks the state's rules.
    func refusing(_ step: CERStep, _ why: String) -> CERState {
        var s = self
        s.rejections.append("\(step.rawValue): \(why)")
        return s
    }

    /// One console line: the fields a step can change, for the debug log.
    var logSummary: String {
        var parts = [
            "intent=\(intent?.rawValue ?? "nil")",
            "classifyAttempts=\(classifyAttempts)",
            "extractAttempts=\(extractAttempts)",
            "calls=\(extraction?.calls.map(\.tool) ?? [])",
            "missing=\(missing)",
            "executed=\(executed)",
            "results=\(results.count)",
            "toolError=\(toolError ?? "nil")",
            "respondAttempts=\(respondAttempts)",
            "say=\"\(say)\"",
        ]
        if !problem.isEmpty { parts.append("problem=\"\(problem)\"") }
        if !rejections.isEmpty { parts.append("rejections=\(rejections)") }
        return parts.joined(separator: " ")
    }
}
