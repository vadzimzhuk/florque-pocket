import Foundation

// Purpose: the seam between the `Assistant` and a turn workflow. A workflow takes one user message and returns
// what the chat shows; it owns its own graph and prompts. `WorkflowFactory` builds a workflow from its id.
//
// Testing: each workflow is tested end to end through `Assistant.handle` (`AssistantTests`, `TurnEvalTests`), and
// each of its steps on its own (`StepEvalTests`).

/// Every turn workflow the app can run. Add a case here and in `WorkflowFactory.make`.
nonisolated enum WorkflowID: String, Sendable, CaseIterable {
    /// Classify, extract tool calls, run them, then respond. Tools: record and retrieve memory nodes and links.
    case cer
}

/// One turn from user message to what the chat shows.
nonisolated protocol TurnWorkflow: Sendable {
    var id: WorkflowID { get }
    /// `history` is the recent chat as "user: …" / "assistant: …" lines, oldest first. Workflows may ignore it.
    func run(_ text: String, policy: RoutePolicy, now: Date, noteId: String, history: [String]) async throws -> AssistantTurn
}

/// Everything a workflow needs. Built once by the `Assistant`.
nonisolated struct TurnDeps: Sendable {
    let store: PocketStore
    let model: any ModelAdapter
    let reminders: (any RemindersAdapter)?
    let timeZone: TimeZone
}

nonisolated enum WorkflowFactory {
    static func make(_ id: WorkflowID, deps: TurnDeps) -> any TurnWorkflow {
        switch id {
        case .cer: CERWorkflow(deps: deps)
        }
    }
}
