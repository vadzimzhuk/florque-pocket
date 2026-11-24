import Foundation

// Purpose: `respond` and its repair. One model call answers from the tool results. If the reply is unusable, the
// repair runs once. If the repair is also unusable, the reducer uses a reply built in code from the results, so the
// user always gets an answer.
// Gate: the tools ran without an error, no reply yet, and the attempt count matches (0 for respond, 1 for the repair).
// Reduce: a reply sets `say`; a rejection counts an attempt (the repair's rejection sets the code-built reply).
//
// Testing: `CERTests` (respond section) covers each stage on its own, including the code-built fallback.

nonisolated struct RespondStep: CERStepKind {
    let repair: Bool

    struct Input: Sendable {
        let turn: CERTurnValues
        let results: [CERToolResult]
        let resultsText: String
    }

    var step: CERStep { repair ? .respondRepair : .respond }

    func gate(_ s: CERState) -> Checked<Input> {
        var problems: [String] = []
//        if !s.executed { problems.append("the tools have not run") }
        if s.toolError != nil { problems.append("a tool failed") }
        if !s.say.isEmpty { problems.append("a reply already exists") }
        if s.respondAttempts != (repair ? 1 : 0) {
            problems.append(repair ? "the repair runs once, after one failed reply" : "the reply already failed once")
        }
        let turn = CERTurnValues(s, repair: repair)
        if let budget = CERModel.budgetProblem(turn, results: s.resultsText) { problems.append(budget) }

        guard problems.isEmpty else { return .rejected(problems.joined(separator: "; ")) }
        return .ok(Input(turn: turn, results: s.results, resultsText: s.resultsText))
    }

    func prompt(_ input: Input) -> ModelPrompt {
        let turn = input.turn
        let results = input.resultsText.isEmpty ? "(none)" : input.resultsText
        let system = repair ? CERPrompts.respondRepair : CERPrompts.respond
        let lines = ["RESULTS:\n\(results)"] + (repair ? ["PROBLEM: \(turn.problem)"] : [])
        return ModelPrompt(system: system, user: CERModel.userMessage(turn, lines: lines), policy: turn.policy)
    }

    func process(_ prompt: ModelPrompt, _ input: Input, _ env: CEREnv) async -> Checked<String> {
        await CERModel.call(prompt, step: step, env: env)
    }

    func parse(_ raw: String, _ input: Input) -> Checked<String> {
        CERParse.say(raw)
    }

    func reduce(_ s: CERState, _ input: Input, _ outcome: Checked<String>) -> CERState {
        var s = s
        switch outcome {
        case .ok(let say):
            guard s.say.isEmpty else { return s.refusing(step, "a reply already exists") }
            s.say = say
        case .rejected(let why):
            s.respondAttempts += 1
            s.problem = why
            if repair {
                // The repaired reply is still unusable: answer from the results in code.
                s.say = Self.fallback(for: input.results)
            }
        }
        return s
    }

    /// The reply built in code from the results. Used only after the repair fails.
    static func fallback(for results: [CERToolResult]) -> String {
        let text = results.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? "Hi! How can I help you today?" : text
    }
}
