import Foundation

// Purpose: the shape every `cer` step shares. A step has five stages, run in this order by `CERStepRunner`:
//   1. gate      (input gatekeeper): checks the state and returns a typed `Input`, or refuses
//   2. prompt    (prompt generator): fills the template from `Input` only, never from the whole state
//   3. process   (the only impure stage): an LLM call, or a deterministic flow (tools)
//   4. parse     (response parser): extracts the expected values from the raw result
//   5. reduce    (reducer): the only code that changes the state, for this step's fields
// A refused gate stops the step before any model call; the runner records the refusal in `rejections`.
// Each stage is logged with `Log.debug("cer", ...)` and kept in `state.log`.
//
// Testing: `CERTests` runs each stage on its own (gate, prompt, process with FakeModel, parse, reduce) and the
// runner contract (a refused gate never calls the model; every stage is logged in order).

/// One logged stage of one step.
nonisolated struct CERLogEntry: Sendable, Equatable {
    let step: CERStep
    let stage: CERStage
    let note: String
}

nonisolated enum CERStage: String, Sendable, Equatable {
    case gate, refused, prompt, process, parse, reduce
}

/// What a step may use from the app.
nonisolated struct CEREnv: Sendable {
    let model: any ModelAdapter
    let store: PocketStore
    let reminders: (any RemindersAdapter)?
}

/// The values every step's `Input` carries: the message, recent history, the classifier's reason, the time, the
/// time zone, the route policy for the call, and the last problem (used by repairs).
nonisolated struct CERTurnValues: Sendable {
    let text: String
    let history: [String]
    let reason: String
    let now: Date
    let timeZone: TimeZone
    let policy: RoutePolicy
    let problem: String
    let typeBlocks: CERTypeBlocks?

    /// `auto` stays on the device for CER turns: person and feeling content must not reach the cloud. Only an
    /// explicit developer choice of cloud sends a turn there.
    init(_ s: CERState) {
        text = s.text
        history = s.history
        reason = s.reason
        now = s.now
        timeZone = s.timeZone
        policy = s.policy == .auto ? .forceOnDevice : s.policy
        problem = s.problem
        typeBlocks = s.typeBlocks
    }
}

/// A model call: the two texts and the route policy.
nonisolated struct ModelPrompt: Sendable, Equatable {
    let system: String
    let user: String
    let policy: RoutePolicy
}

/// The prompt of a deterministic step: there is nothing to send.
nonisolated struct NoPrompt: Sendable, Equatable {}

/// One step of the `cer` graph. Conforming types are small structs (see `ClassifyStep`, `ExecuteStep`, ...).
nonisolated protocol CERStepKind: Sendable {
    associatedtype Input: Sendable
    associatedtype Prompt: Sendable
    associatedtype Raw: Sendable
    associatedtype Output: Sendable

    var step: CERStep { get }
    /// 1. Input gatekeeper. Returns the typed input, or the reason the step must not run.
    func gate(_ s: CERState) -> Checked<Input>
    /// 2. Prompt generator. Uses only the input.
    func prompt(_ input: Input) -> Prompt
    /// 3. Processing: an LLM call or a deterministic flow. A `.rejected` here skips parse and goes to reduce.
    func process(_ prompt: Prompt, _ input: Input, _ env: CEREnv) async -> Checked<Raw>
    /// 4. Response parser. Extracts the expected values, or says why they are not there.
    func parse(_ raw: Raw, _ input: Input) -> Checked<Output>
    /// 5. Reducer. Changes this step's fields for an ok or rejected outcome; refuses what breaks the state's rules.
    func reduce(_ s: CERState, _ input: Input, _ outcome: Checked<Output>) -> CERState
}

/// Runs the five stages of a step and logs each one.
nonisolated enum CERStepRunner {
    static func run<S: CERStepKind>(_ kind: S, _ state: CERState, env: CEREnv) async -> CERState {
        var s = state
        let name = kind.step

        func log(_ stage: CERStage, _ note: String) {
            s.log.append(CERLogEntry(step: name, stage: stage, note: note))
            Log.debug("cer", "\(name.rawValue) \(stage.rawValue): \(note)")
        }

        let input: S.Input

        switch kind.gate(state) {
        case .rejected(let why):
            log(.refused, why)
            s.rejections.append("\(name.rawValue): \(why)")
            return s
        case .ok(let value):
            input = value
        }
        log(.gate, "ok")

        let prompt = kind.prompt(input)
        log(.prompt, "built")

        let outcome: Checked<S.Output>

        switch await kind.process(prompt, input, env) {
        case .rejected(let why):
            outcome = .rejected(why)
        case .ok(let raw):
            outcome = kind.parse(raw, input)
        }

        switch outcome {
        case .ok: log(.parse, "ok")
        case .rejected(let why): log(.parse, "rejected: \(why)")
        }

        s = kind.reduce(s, input, outcome)
        log(.reduce, s.logSummary)
        return s
    }

    /// The graph's node for a step name: picks the step's type and runs it.
    static func runNamed(_ step: CERStep, _ state: CERState, env: CEREnv) async -> CERState {
        switch step {
        case .classify: await run(ClassifyStep(repair: false), state, env: env)
        case .classifyRepair: await run(ClassifyStep(repair: true), state, env: env)
        case .extract: await run(ExtractStep(repair: false), state, env: env)
        case .extractRepair: await run(ExtractStep(repair: true), state, env: env)
        case .execute: await run(ExecuteStep(), state, env: env)
        case .respond: await run(RespondStep(repair: false), state, env: env)
        case .respondRepair: await run(RespondStep(repair: true), state, env: env)
        case .clarify: await run(ClarifyStep(), state, env: env)
        }
    }
}

/// Helpers the LLM steps share: the model call, the user message, the budget check.
nonisolated enum CERModel {
    /// One model call. A thrown error becomes a rejected outcome, so the reducer can count the attempt.
    static func call(_ prompt: ModelPrompt, step: CERStep, env: CEREnv) async -> Checked<String> {
        let tokens = TokenBudget.estimate(prompt.system) + TokenBudget.estimate(prompt.user)
        Log.debug("cer", "\(step.rawValue) model input ≈\(tokens) tokens (limit \(TokenBudget.inputLimit))")
        do {
            let reply = try await env.model.generate(system: prompt.system, user: prompt.user, policy: prompt.policy)
            Log.debug("cer", "\(step.rawValue) reply [\(Assistant.label(reply, policy: prompt.policy))]: \(reply.text)")
            return .ok(reply.text)
        } catch {
            Log.debug("cer", "\(step.rawValue) model failed: \(error)")
            return .rejected("the model call failed")
        }
    }

    /// The user side of a prompt: recent history, the message, the reason, then the step's own lines.
    static func userMessage(_ turn: CERTurnValues, lines: [String]) -> String {
        var parts: [String] = []
        if !turn.history.isEmpty { parts.append("HISTORY:\n" + turn.history.joined(separator: "\n")) }
        parts.append("MESSAGE: " + TokenBudget.clip(turn.text, TokenBudget.maxMessageChars))
        if !turn.reason.isEmpty { parts.append("REASON: \(turn.reason)") }
        parts += lines
        return parts.joined(separator: "\n")
    }

    /// A refusal reason when the input (message, history and results) would exceed the token limit, else nil.
    static func budgetProblem(_ turn: CERTurnValues, results: String = "") -> String? {
        let tokens = TokenBudget.inputTokens(text: turn.text, history: turn.history, results: results)
        return tokens > TokenBudget.inputLimit ? "the input is \(tokens) tokens, over \(TokenBudget.inputLimit)" : nil
    }
}
