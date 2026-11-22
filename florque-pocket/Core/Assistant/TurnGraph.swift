import AgentKit
import Foundation

// Purpose: the pieces every workflow shares: one model call followed by the tool executor on its reply.
// Testing: covered through the workflows (`TurnEvalTests`, `StepEvalTests`, `AssistantTests`).

/// One model reply and what the executor did with it.
nonisolated struct Attempt: Sendable {
    var reply: ModelReply
    var outcome: ToolOutcome
}

/// One model call, then the executor on its reply. Shared by every workflow.
/// The executor's allow-list (`allowedTools`, `allowedTypes`) decides what this step may write.
nonisolated func runAttempt(_ user: String, system: String, policy: RoutePolicy, now: Date,
                            model: any ModelAdapter, executor: ToolExecutor) async throws -> Attempt {
    let reply = try await model.generate(system: system, user: user, policy: policy)
    let outcome = await executor.run(reply: reply.text, now: now)
    return Attempt(reply: reply, outcome: outcome)
}
