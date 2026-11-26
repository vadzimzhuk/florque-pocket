import AgentKit
import Foundation

// Purpose: the entry point the chat calls. It runs one user message through the `cer` workflow and returns what the
// chat shows, with the changeset that lets the turn be undone.
//
// Testing: `CERTests` and `GraphQueriesTests` run whole turns through `Assistant.handle` and `Assistant.undo` on an
// in-memory store, with a scripted model and fake reminders.

/// What the chat shows for one user message.
public struct AssistantTurn: Sendable, Equatable {
    public var say: String
    public var routeLabel: String
    /// The message's id, which ties the turn to its chat entry.
    public var noteId: String
    /// Actions the output gate refused during the turn, as "step: reason". Empty when every step kept its contract.
    public var gateRejections: [String] = []
    /// What the turn wrote to the graph, so the chat can undo it. Nil when nothing was written.
    public var changeset: GraphChangeset? = nil
}

/// Runs one turn through the chosen workflow and undoes a turn's graph writes.
public actor Assistant {
    private let store: PocketStore
    private let workflow: any TurnWorkflow
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    init(store: PocketStore,
         model: any ModelAdapter,
         clock: @escaping @Sendable () -> Date = { Date() },
         timeZone: TimeZone = .current,
         workflow: WorkflowID = .cer,
         reminders: (any RemindersAdapter)? = nil) {
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        let deps = TurnDeps(store: store, model: model, reminders: reminders, timeZone: timeZone)
        self.workflow = WorkflowFactory.make(workflow, deps: deps)
    }

    /// Runs one message. `history` is the recent chat, oldest first, as "user: …" / "assistant: …" lines.
    public func handle(_ text: String, policy: RoutePolicy, history: [String] = []) async throws -> AssistantTurn {
        try await workflow.run(text, policy: policy, now: clock(), noteId: UUID().uuidString.lowercased(), history: history)
    }

    /// Reverses one turn's graph writes and removes the reminders it created.
    public func undo(_ changeset: GraphChangeset, reminders: (any RemindersAdapter)?) async throws {
        if let reminders {
            for identifier in changeset.reminderIds {
                try? await reminders.deleteReminder(identifier: identifier)
            }
        }
        try await store.undo(changeset)
    }

    // MARK: helpers shared by the workflows

    static func label(_ reply: ModelReply, policy: RoutePolicy) -> String {
        let place: String
        switch reply.route {
        case .onDevice: place = "On-device"
        case .cloud: place = policy == .forceCloud ? "Cloud (forced)" : "Cloud"
        }
        return "\(place) · \(String(format: "%.1f", reply.seconds)) s"
    }
}
