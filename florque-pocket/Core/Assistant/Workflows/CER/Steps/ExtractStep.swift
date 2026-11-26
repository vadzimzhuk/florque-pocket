import Foundation

// Purpose: `extract` and its repair. The classifier has already chosen the tool; one model call fills that tool's
// arguments only. A required argument left out (for example `when` for an event) is not an error here: the parser
// reports it in `missing`, and the workflow asks the user.
// Gate: the intent needs a tool (not chat or unclear), no extraction yet, and the attempt count matches.
// Reduce: an extraction sets `extraction`; a rejection counts an attempt and keeps the problem.
//
// Testing: `CERTests` (extract section) covers each stage on its own.

nonisolated struct ExtractStep: CERStepKind {
    let repair: Bool

    struct Input: Sendable {
        let turn: CERTurnValues
        let intent: CERIntent
        let tool: any CERTool
    }

    var step: CERStep { repair ? .extractRepair : .extract }

    func gate(_ s: CERState) -> Checked<Input> {
        var problems: [String] = []
        guard let intent = s.intent else {
            return .rejected("the message is not classified")
        }
        guard let tool = CERToolbox.tool(for: intent) else {
            problems.append("the intent \(intent.rawValue) takes no extraction")
            return .rejected(problems.joined(separator: "; "))
        }
        if s.extraction != nil { problems.append("the message is already extracted") }
        if s.extractAttempts != (repair ? 1 : 0) {
            problems.append(repair ? "the repair runs once, after one failed extraction" : "the extraction already ran")
        }
        let turn = CERTurnValues(s, repair: repair)
        if let budget = CERModel.budgetProblem(turn) { problems.append(budget) }
        guard problems.isEmpty else { return .rejected(problems.joined(separator: "; ")) }
        return .ok(Input(turn: turn, intent: intent, tool: tool))
    }

    func prompt(_ input: Input) -> ModelPrompt {
        let turn = input.turn
        // Only the record tool needs the type lists: it chooses node and link types from them.
        let types = input.tool.name == "record" ? turn.typeBlocks : nil
        let system = repair
            ? CERPrompts.extractRepair(tool: input.tool, now: turn.now, timeZone: turn.timeZone, types: types)
            : CERPrompts.extract(tool: input.tool, now: turn.now, timeZone: turn.timeZone, types: types)
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
