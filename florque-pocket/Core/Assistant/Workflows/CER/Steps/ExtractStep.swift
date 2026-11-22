import Foundation

// Purpose: `extract` and its repair. One model call picks the tools for the classified intent and fills their
// arguments. Only that intent's tools are listed in the prompt, so it stays small. A record_event without a time is
// not an error here: the parser puts "time" in `missing` and the workflow goes to clarify.
// Gate: an intent that takes tools (record, retrieve, chat), no extraction yet, and the attempt count matches.
// Reduce: an extraction sets `extraction`; a rejection counts an attempt and keeps the problem.
//
// Testing: `CERTests` (extract section) covers each stage on its own.

nonisolated struct ExtractStep: CERStepKind {
    let repair: Bool

    struct Input: Sendable {
        let turn: CERTurnValues
        let intent: CERIntent
    }

    var step: CERStep { repair ? .extractRepair : .extract }

    func gate(_ s: CERState) -> Checked<Input> {
        var problems: [String] = []
        guard let intent = s.intent else {
            return .rejected("the message is not classified")
        }
        if !(intent == .record || intent == .retrieve || intent == .chat) {
            problems.append("the intent \(intent.rawValue) takes no extraction")
        }
        if s.extraction != nil { problems.append("the message is already extracted") }
        if s.extractAttempts != (repair ? 1 : 0) {
            problems.append(repair ? "the repair runs once, after one failed extraction" : "the extraction already ran")
        }
        let turn = CERTurnValues(s, repair: repair)
        if let budget = CERModel.budgetProblem(turn) { problems.append(budget) }
        return problems.isEmpty ? .ok(Input(turn: turn, intent: intent)) : .rejected(problems.joined(separator: "; "))
    }

    func prompt(_ input: Input) -> ModelPrompt {
        let turn = input.turn
        let system = repair
            ? CERPrompts.extractRepair(intent: input.intent, now: turn.now, timeZone: turn.timeZone)
            : CERPrompts.extract(intent: input.intent, now: turn.now, timeZone: turn.timeZone)
        let user = CERModel.userMessage(turn, lines: repair ? ["PROBLEM: \(turn.problem)"] : [])
        return ModelPrompt(system: system, user: user, policy: turn.policy)
    }

    func process(_ prompt: ModelPrompt, _ input: Input, _ env: CEREnv) async -> Checked<String> {
        await CERModel.call(prompt, step: step, env: env)
    }

    func parse(_ raw: String, _ input: Input) -> Checked<CERExtraction> {
        CERParse.extract(raw, intent: input.intent)
    }

    func reduce(_ s: CERState, _ input: Input, _ outcome: Checked<CERExtraction>) -> CERState {
        var s = s
        switch outcome {
        case .ok(let extraction):
            guard s.extraction == nil else { return s.refusing(step, "the message is already extracted") }
            s.extraction = extraction
            s.problem = ""
        case .rejected(let why):
            s.extractAttempts += 1
            s.problem = why
        }
        return s
    }
}
