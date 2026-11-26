import Foundation

// Purpose: `execute`, the deterministic step. No prompt and no model call: it runs the extracted tool calls, in order,
// through the toolbox. A retrieve with no hits and a text query is run once more without the query. A tool error
// is a rejected outcome, which the reducer keeps as `toolError` (the workflow then asks the user).
// Gate: an extraction exists with nothing missing, and the tools have not run yet.
// Reduce: results set `results`; a rejection sets `toolError`. Either way `executed` becomes true.
//
// Testing: `CERTests` (execute section) runs the tools on an in-memory store.

nonisolated struct ExecuteStep: CERStepKind {
    struct Input: Sendable {
        let extraction: CERExtraction
        let turn: CERTurnValues
    }

    var step: CERStep { .execute }

    func gate(_ s: CERState) -> Checked<Input> {
        var problems: [String] = []
        if s.extraction == nil { problems.append("nothing was extracted") }
        if !s.missing.isEmpty { problems.append("something is missing: \(s.missing.joined(separator: ", "))") }
        if s.executed { problems.append("the tools already ran") }
        guard let extraction = s.extraction, problems.isEmpty else {
            return .rejected(problems.joined(separator: "; "))
        }
        return .ok(Input(extraction: extraction, turn: CERTurnValues(s, repair: false)))
    }

    func prompt(_ input: Input) -> NoPrompt {
        NoPrompt()
    }

    func process(_ prompt: NoPrompt, _ input: Input, _ env: CEREnv) async -> Checked<[CERToolResult]> {
        let context = CERToolContext(store: env.store, timeZone: input.turn.timeZone, now: input.turn.now,
                                     reminders: env.reminders)
        var results: [CERToolResult] = []
        for call in input.extraction.calls {
            guard let tool = CERToolbox.tool(named: call.tool) else {
                return .rejected("\(call.tool): unknown tool")
            }
            do {
                var result = try await tool.run(call.args, context)
                if result.items.isEmpty, tool.name == "retrieve", call.args["query"] != nil {
                    var broader = call.args
                    broader["query"] = nil
                    result = try await tool.run(broader, context)
                }
                results.append(result)
            } catch let error as CERToolError {
                return .rejected("\(call.tool): \(error.message)")
            } catch {
                return .rejected("\(call.tool): \(error.localizedDescription)")
            }
        }
        return .ok(results)
    }

    /// Nothing to parse: the tool results are already typed.
    func parse(_ raw: [CERToolResult], _ input: Input) -> Checked<[CERToolResult]> {
        .ok(raw)
    }

    func reduce(_ s: CERState, _ input: Input, _ outcome: Checked<[CERToolResult]>) -> CERState {
        var s = s
        guard !s.executed else { return s.refusing(step, "the tools already ran") }
        s.executed = true
        switch outcome {
        case .ok(let results): s.results = results
        case .rejected(let why): s.toolError = why
        }
        return s
    }
}
