import AgentKit
import Foundation

// Purpose: the entry point the chat calls. It runs one user message through the chosen workflow and offers the
// two actions the chat can take on a task: accept (activate it, with a reminder) and dismiss (drop it).
//
// Testing: `AssistantTests` runs the intent workflow end to end on an in-memory store with a fake model and fake
// reminders, and checks accept and dismiss against the stored task objects.

/// A task waiting for Accept or Dismiss. No workflow creates these now; the `intent` workflow saves tasks as active.
public struct TaskProposal: Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// What the chat shows for one user message.
public struct AssistantTurn: Sendable, Equatable {
    public var say: String
    public var routeLabel: String
    /// Tasks waiting for Accept or Dismiss. Always empty: no workflow creates proposals.
    public var proposals: [TaskProposal]
    public var proposalIds: [String] { proposals.map(\.id) }
    /// The message's note. For `intent` it exists only when a note was saved (see `intents`).
    public var noteId: String
    /// True when the model could not structure the message; the note is still saved.
    public var savedOnly: Bool
    /// What the classifier decided.
    public var intents: [Intent] = []
    /// Tasks saved directly by the `intent` workflow, each with `active` status.
    public var taskIds: [String] = []
    /// True when a task was saved but its reminder could not be created.
    public var reminderFailed = false
    /// Actions the output gate refused during the turn, as "step: reason". Empty when every step kept its contract.
    public var gateRejections: [String] = []
    /// What the turn wrote to the graph, so the chat can undo it. Nil when nothing was written.
    public var changeset: GraphChangeset? = nil
}

/// Runs one turn through the chosen workflow and owns the task actions the chat needs (accept, dismiss).
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
         prompts: PromptSet = .current,
         reminders: (any RemindersAdapter)? = nil) {
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        let deps = TurnDeps(store: store, model: model, prompts: prompts, reminders: reminders, timeZone: timeZone)
        self.workflow = WorkflowFactory.make(workflow, deps: deps)
    }

    /// Runs one message. `history` is the recent chat, oldest first, as "user: …" / "assistant: …" lines.
    public func handle(_ text: String, policy: RoutePolicy, history: [String] = []) async throws -> AssistantTurn {
        try await workflow.run(text, policy: policy, now: clock(), noteId: UUID().uuidString.lowercased(), history: history)
    }

    /// Accepts a task: it becomes active and, if it has a due time and no reminder yet, gets one.
    public func accept(taskId: String, reminders: (any RemindersAdapter)?) async throws {
        guard let task = try await store.task(id: taskId) else { return }
        try await store.setStatus(.active, taskId: taskId, now: clock())
        if let reminders, let due = task.due, task.eventId == nil {
            let eventId = try await reminders.createReminder(title: task.title, due: due)
            try await store.setEventId(eventId, taskId: taskId)
        }
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

    /// Drops a task: it stays in the store but leaves the open list, answers and the digest.
    public func dismiss(taskId: String) async throws {
        guard try await store.task(id: taskId) != nil else { return }
        try await store.setStatus(.dropped, taskId: taskId, now: clock())
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
