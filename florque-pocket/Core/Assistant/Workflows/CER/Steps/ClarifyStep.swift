import Foundation

// Purpose: `clarify`. One model call asks the user one short question for what is missing, or for the unclear
// intent, or for a failed tool. If the model fails, the reducer uses a fixed question, so the turn always ends with one.
// Gate: no question yet, and the state needs one (CERState.needsQuestion).
// Reduce: a reply sets `question` and `say`; a rejection uses the fixed question for the state.
//
// Testing: `CERTests` (clarify section) covers each stage on its own.

nonisolated struct ClarifyStep: CERStepKind {
    struct Input: Sendable {
        let turn: CERTurnValues
        let missing: [String]
        let toolError: String?
        let intent: CERIntent?
    }

    var step: CERStep { .clarify }

    func gate(_ s: CERState) -> Checked<Input> {
        var problems: [String] = []
        if s.question != nil { problems.append("the question was already asked") }
        if !s.needsQuestion { problems.append("nothing needs a question") }
        guard problems.isEmpty else { return .rejected(problems.joined(separator: "; ")) }
        return .ok(Input(turn: CERTurnValues(s, repair: false), missing: s.missing, toolError: s.toolError,
                         intent: s.intent))
    }

    func prompt(_ input: Input) -> ModelPrompt {
        var lines: [String] = []
        if !input.missing.isEmpty { lines.append("MISSING: \(input.missing.joined(separator: ", "))") }
        if let error = input.toolError { lines.append("TOOL ERROR: \(error)") }
        return ModelPrompt(system: CERPrompts.clarify, user: CERModel.userMessage(input.turn, lines: lines),
                           policy: input.turn.policy)
    }

    func process(_ prompt: ModelPrompt, _ input: Input, _ env: CEREnv) async -> Checked<String> {
        await CERModel.call(prompt, step: step, env: env)
    }

    func parse(_ raw: String, _ input: Input) -> Checked<String> {
        CERParse.say(raw)
    }

    func reduce(_ s: CERState, _ input: Input, _ outcome: Checked<String>) -> CERState {
        var s = s
        guard s.question == nil else { return s.refusing(step, "the question was already asked") }
        let question: String
        switch outcome {
        case .ok(let say): question = say
        case .rejected: question = Self.fixedQuestion(missing: input.missing, toolError: input.toolError)
        }
        s.question = question
        s.say = question
        return s
    }

    /// The question used when the model gives no usable one.
    static func fixedQuestion(missing: [String], toolError: String?) -> String {
        if missing.contains("when") { return "When should it happen? Please give a date and time." }
        if missing.contains("title") { return "What is the title?" }
        if missing.contains("body") { return "What should I save?" }
        if let error = toolError { return "I couldn't do that: \(error). Could you rephrase it?" }
        return "What would you like to do: save a note, add an event, or look something up?"
    }
}
