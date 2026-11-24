import Foundation

// Purpose: `classify` and its repair. One model call returns the intent and a short reason. The repair runs once,
// after a failed classification, with the problem in the prompt and the cloud under `auto`.
// Gate: the message is not empty, no intent yet, and the attempt count matches (0 for classify, 1 for the repair).
// Reduce: an intent sets `intent` and `reason`; a rejection counts an attempt and keeps the problem.
//
// Testing: `CERTests` (classify section) covers each stage on its own.

nonisolated struct ClassifyStep: CERStepKind {
    let repair: Bool

    struct Input: Sendable {
        let turn: CERTurnValues
    }

    var step: CERStep { repair ? .classifyRepair : .classify }

    func gate(_ s: CERState) -> Checked<Input> {
        var problems: [String] = []
        if s.intent != nil { problems.append("the message is already classified") }
        if repair {
            if s.classifyAttempts != 1 { problems.append("the repair runs once, after one failed classification") }
        } else {
            if s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("the message is empty") }
            if s.classifyAttempts != 0 { problems.append("the classifier already ran") }
        }
        let turn = CERTurnValues(s, repair: repair)
        if let budget = CERModel.budgetProblem(turn) { problems.append(budget) }
        return problems.isEmpty ? .ok(Input(turn: turn)) : .rejected(problems.joined(separator: "; "))
    }

    func prompt(_ input: Input) -> ModelPrompt {
        let turn = input.turn
        let system = repair ? CERPrompts.classifyRepair : CERPrompts.classify(now: turn.now, timeZone: turn.timeZone)
        let user = CERModel.userMessage(turn, lines: repair ? ["PROBLEM: \(turn.problem)"] : [])
        return ModelPrompt(system: system, user: user, policy: turn.policy)
    }

    func process(_ prompt: ModelPrompt, _ input: Input, _ env: CEREnv) async -> Checked<String> {
        await CERModel.call(prompt, step: step, env: env)
    }

    func parse(_ raw: String, _ input: Input) -> Checked<CERClassifyOutput> {
        CERParse.classify(raw)
    }

    func reduce(_ s: CERState, _ input: Input, _ outcome: Checked<CERClassifyOutput>) -> CERState {
        var s = s
        switch outcome {
        case .ok(let out):
            guard s.intent == nil else { return s.refusing(step, "the message is already classified") }
            s.intent = out.intent
            s.reason = out.reason
            s.problem = ""
            // A chat message needs no tool: an empty extraction lets the turn go straight to execute.
            if out.intent == .chat { s.extraction = CERExtraction(calls: [], missing: []) }
        case .rejected(let why):
            s.classifyAttempts += 1
            s.problem = why
        }
        return s
    }
}
