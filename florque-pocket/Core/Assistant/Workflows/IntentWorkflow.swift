import AgentKit
import Foundation

// Purpose: the `intent` turn graph, wiring only. Each node runs one step through `perform`:
//   input gate (IntentGate) -> model processing (IntentSteps) -> output gate (IntentReducer).
// The routing reads the same gates, so the graph only goes to a step that is allowed to run.
//
// Graph: classify -> (repair -> escalate -> fallback) -> saveNote / extractTask / answer -> followUp, or clarify.
//
// Testing: `IntentStepTests` covers each step's input gate, model processing and output gate. `TurnEvalTests`
// scores whole turns on the labelled corpus, and `AssistantTests` covers the routes and the writes.

/// The `intent` workflow: classify, then one step per intent, then the turn's result.
/// Notes and tasks save directly. Discussion and clarification write nothing.
nonisolated struct IntentWorkflow: TurnWorkflow {
    let id = WorkflowID.intent
    let deps: TurnDeps
    var promptFactory: any WorkflowPromptFactory { IntentPromptFactory() }

    func run(_ text: String, policy: RoutePolicy, now: Date, noteId: String, history: [String]) async throws -> AssistantTurn {
        let context = try await deps.promptContext(noteId: noteId, now: now)
        let systems = promptFactory.renderAll(deps.prompts, context)
        let env = IntentEnv(model: deps.model, store: deps.store, reminders: deps.reminders,
                            timeZone: deps.timeZone, systems: systems)
        let graph = Self.makeGraph(env: env)
        Log.debug("intent", "turn start: \"\(text)\" policy=\(policy.rawValue)")
        let final = try await graph.invoke(state: IntentTurnState(text: text, policy: policy, now: now, noteId: noteId))
        Log.debug("intent", "turn end: say=\"\(final.say)\" rejections=\(final.rejections)")
        return AssistantTurn(say: final.say.isEmpty ? "Done." : final.say,
                             routeLabel: final.route,
                             proposals: [],
                             noteId: noteId,
                             savedOnly: false,
                             intents: final.intents.sorted { $0.rawValue < $1.rawValue },
                             taskIds: final.taskIds,
                             reminderFailed: final.reminderFailed,
                             gateRejections: final.rejections)
    }

    /// Runs one step on the app state: the input gate first, then model processing, then the reducer for each action.
    /// A step whose input gate fails is recorded as rejected and does not call the model or the store.
    static func perform(_ step: IntentStep, _ state: IntentTurnState, env: IntentEnv) async -> IntentTurnState {
        var store = IntentStore(state)
        Log.debug("intent", "step \(step.rawValue) start | \(state.logSummary)")
        let problems = IntentGate.input(step, store.state)
        guard problems.isEmpty else {
            Log.debug("intent", "step \(step.rawValue) refused by input gate: \(problems)")
            store.dispatch(.rejected(step, problems))
            return store.state
        }
        for action in await IntentSteps.process(step, store.state, env: env) {
            Log.debug("intent", "step \(step.rawValue) action: \(action)")
            store.dispatch(action)
        }
        Log.debug("intent", "step \(step.rawValue) done | \(store.state.logSummary)")
        return store.state
    }

    /// The `intent` graph. Every step is a node that calls `perform`; the edges come from the gates.
    private nonisolated static func makeGraph(env: IntentEnv) -> CompiledGraph<IntentTurnState> {
        let graph = StateGraph<IntentTurnState>()
        for step in IntentStep.allCases {
            graph.addNode(step.rawValue) { state in await perform(step, state, env: env) }
        }

        graph.addConditionalEdge(from: IntentStep.classify.rawValue) { state in afterClassify(state) }
        graph.addConditionalEdge(from: IntentStep.repair.rawValue) { state in afterClassify(state) }
        graph.addConditionalEdge(from: IntentStep.escalate.rawValue) { state in afterClassify(state) }
        graph.addEdge(from: IntentStep.fallback.rawValue, to: IntentStep.clarify.rawValue)
        graph.addConditionalEdge(from: IntentStep.saveNote.rawValue) { state in route(state) }
        graph.addConditionalEdge(from: IntentStep.extractTask.rawValue) { state in route(state) }
        graph.addConditionalEdge(from: IntentStep.answer.rawValue) { state in answerRoute(state) }
        graph.addEdge(from: IntentStep.followUp.rawValue, to: StateGraphConstants.end)
        graph.addEdge(from: IntentStep.clarify.rawValue, to: StateGraphConstants.end)
        graph.setEntryPoint(IntentStep.classify.rawValue)

        do {
            return try graph.compile()
        } catch {
            fatalError("Failed to compile the intent graph: \(error)")
        }
    }

    /// After any classifier step: route on the intents, or retry, escalate once, then fall back to a note.
    private nonisolated static func afterClassify(_ state: IntentTurnState) -> String {
        if state.classifyOK { return route(state) }
        if IntentGate.input(.repair, state).isEmpty { return IntentStep.repair.rawValue }
        if IntentGate.input(.escalate, state).isEmpty { return IntentStep.escalate.rawValue }
        return IntentStep.fallback.rawValue
    }

    /// The next step the gates allow, or the end of the graph.
    private nonisolated static func route(_ state: IntentTurnState) -> String {
        IntentGate.next(state)?.rawValue ?? StateGraphConstants.end
    }

    private nonisolated static func answerRoute(_ state: IntentTurnState) -> String {
        if IntentGate.input(.followUp, state).isEmpty { return IntentStep.followUp.rawValue }
        if IntentGate.input(.clarify, state).isEmpty { return IntentStep.clarify.rawValue }
        return StateGraphConstants.end
    }
}
