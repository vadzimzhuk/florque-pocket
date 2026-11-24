import Foundation

// Purpose: the seam between the `Assistant` and a turn workflow. A workflow takes one user message and returns
// what the chat shows; it owns its own graph and prompts. `WorkflowFactory` builds a workflow from its id.
//
// Testing: each workflow is tested end to end through `Assistant.handle` (`AssistantTests`, `TurnEvalTests`), and
// each of its steps on its own (`StepEvalTests`).

/// Every turn workflow the app can run. Add a case here and in `WorkflowFactory.make`.
nonisolated enum WorkflowID: String, Sendable, CaseIterable {
    /// Classify the intent first, then one step per intent: save a note, extract a task, answer, or clarify.
    case intent
    /// Classify, extract tool calls, run them, then respond. Tools: record and retrieve notes and events.
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
    let prompts: PromptSet
    let reminders: (any RemindersAdapter)?
    let timeZone: TimeZone

    /// Prompt inputs for the current store state: open tasks and recent notes, as the digest shows them.
    func promptContext(noteId: String, now: Date) async throws -> PromptContext {
        let tasks = try await store.openTasks()
        let notes = try await store.recentNotes(limit: 20)
        return PromptContext(now: now,
                             timeZone: timeZone,
                             digest: Digest.build(tasks: tasks, notes: notes, timeZone: timeZone),
                             noteId: noteId)
    }
}

nonisolated enum WorkflowFactory {
    static func make(_ id: WorkflowID, deps: TurnDeps) -> any TurnWorkflow {
        switch id {
        case .intent: IntentWorkflow(deps: deps)
        case .cer: CERWorkflow(deps: deps)
        }
    }
}
