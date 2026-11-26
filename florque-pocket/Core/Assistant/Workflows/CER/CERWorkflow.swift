import AgentKit
import Foundation

// Purpose: the `cer` turn graph (classify → extract → execute → respond, with clarify), wiring only. Each node runs one
// step through `perform`, which runs the step's five stages (gate → prompt → process → parse → reduce, see
// `Steps/CERStepKind.swift`). The routes read the state the reducers wrote, so the graph only goes to a step the state allows.
//
// Graph:
//   classify ─ unclear / failed twice ─→ clarify
//            ─ failed once ─→ classifyRepair ─→ extract (or clarify)
//            ─ record / retrieve / chat ─→ extract
//   extract  ─ missing (e.g. event time) ─→ clarify
//            ─ failed once ─→ extractRepair ─→ execute (or clarify)
//            ─ ok ─→ execute
//   execute  ─ tool error ─→ clarify ; else ─→ respond
//   respond  ─ no reply ─→ respondRepair ─→ end ; reply ─→ end
//   clarify  ─→ end
// Every loop is bounded by the counters in the state, and `invoke(maxSteps: 12)` bounds the graph as a whole.
//
// Testing: `CERTests` (each step's stages, the runner contract, and whole turns), `CERBudgetTests` (token limit).

/// The `cer` workflow: classify the message, extract tool calls, run the tools, then answer or ask a question.
nonisolated struct CERWorkflow: TurnWorkflow {
    let id = WorkflowID.cer
    let deps: TurnDeps

    func run(_ text: String, policy: RoutePolicy, now: Date, noteId: String, history: [String]) async throws -> AssistantTurn {
        let env = CEREnv(model: deps.model, store: deps.store, reminders: deps.reminders)
        var state = CERState(text: text, history: TokenBudget.history(history), policy: policy, now: now,
                             noteId: noteId, timeZone: deps.timeZone)
        // The enabled node and link types for this message, so the record tool only chooses from them.
        let snapshot = try await deps.store.snapshot()
        state.typeBlocks = CERTypeBlocks(
            nodes: GraphPromptBlocks.nodeTypesBlock(snapshot.nodeTypes, message: text),
            edges: GraphPromptBlocks.edgeTypesBlock(snapshot.edgeTypes, nodeTypes: snapshot.nodeTypes, message: text))
        Log.debug("cer", "turn start: \"\(text)\" policy=\(policy.rawValue) history=\(state.history.count)")

        let final = try await Self.makeGraph(env: env).invoke(state: state, maxSteps: 12)
        Log.debug("cer", "turn end: say=\"\(final.say)\" rejections=\(final.rejections)")

        let written = final.results.filter { $0.changeset != nil }
        return AssistantTurn(say: final.say.isEmpty ? "Done." : final.say,
                             routeLabel: "",
                             noteId: noteId,
                             gateRejections: final.rejections,
                             changeset: GraphChangeset.combined(written.compactMap(\.changeset)),
                             actionLabel: written.isEmpty ? nil : written.map(\.summary).joined(separator: " "))
    }

    /// The graph node for one step: the step's five stages, in order. A refused gate stops the step before any model call.
    static func perform(_ step: CERStep, _ state: CERState, env: CEREnv) async -> CERState {
        await CERStepRunner.runNamed(step, state, env: env)
    }

    private nonisolated static func makeGraph(env: CEREnv) -> CompiledGraph<CERState> {
        let graph = StateGraph<CERState>()
        let steps: [CERStep] = [
            .classify,
            .classifyRepair,
            .extract,
            .extractRepair,
            .execute,
            .respond,
            .respondRepair,
            .clarify
        ]

        for step in steps {
            graph.addNode(step.rawValue) { state in await perform(step, state, env: env) }
        }

        graph.addConditionalEdge(from: CERStep.classify.rawValue) { s in afterClassify(s) }
        graph.addConditionalEdge(from: CERStep.classifyRepair.rawValue) { s in afterClassify(s) }
        graph.addConditionalEdge(from: CERStep.extract.rawValue) { s in afterExtract(s) }
        graph.addConditionalEdge(from: CERStep.extractRepair.rawValue) { s in afterExtract(s) }
        graph.addConditionalEdge(from: CERStep.execute.rawValue) { s in s.toolError == nil ? CERStep.respond.rawValue : CERStep.clarify.rawValue }
        graph.addConditionalEdge(from: CERStep.respond.rawValue) { s in s.say.isEmpty ? CERStep.respondRepair.rawValue : StateGraphConstants.end }
        graph.addEdge(from: CERStep.respondRepair.rawValue, to: StateGraphConstants.end)
        graph.addEdge(from: CERStep.clarify.rawValue, to: StateGraphConstants.end)

        graph.setEntryPoint(CERStep.classify.rawValue)
        
        do {
            return try graph.compile()
        } catch {
            fatalError("Failed to compile the cer graph: \(error)")
        }
    }

    /// A classified message goes to extract (unclear goes to clarify). Otherwise retry once, then clarify.
    private nonisolated static func afterClassify(_ s: CERState) -> String {
        if let intent = s.intent {
            switch intent {
            case .chat:
                return CERStep.respond.rawValue
            case .unclear:
                return CERStep.clarify.rawValue
            default:
                return CERStep.extract.rawValue
            }
        }
        
        return s.classifyAttempts == 1 ? CERStep.classifyRepair.rawValue : CERStep.clarify.rawValue
    }

    /// Extraction that found everything goes to execute. Missing details go to clarify. A failed extraction is retried once.
    private nonisolated static func afterExtract(_ s: CERState) -> String {
        if let extraction = s.extraction {
            return extraction.missing.isEmpty ? CERStep.execute.rawValue : CERStep.clarify.rawValue
        }
        return s.extractAttempts == 1 ? CERStep.extractRepair.rawValue : CERStep.clarify.rawValue
    }
}
