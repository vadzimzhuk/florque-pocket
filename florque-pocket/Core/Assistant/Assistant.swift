import Foundation

/// A task waiting for Accept or Dismiss.
public struct TaskProposal: Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// What the chat shows for one user message.
public struct AssistantTurn: Sendable, Equatable {
    public var say: String
    public var routeLabel: String
    /// Tasks created as proposals, waiting for Accept or Dismiss.
    public var proposals: [TaskProposal]
    public var proposalIds: [String] { proposals.map(\.id) }
    public var noteId: String
    /// True when the model could not structure the message; the note is still saved.
    public var savedOnly: Bool
}

/// One model reply and what the executor did with it.
private struct Attempt: Sendable {
    var reply: ModelReply
    var outcome: ToolOutcome
}

/// What every step of one turn needs.
private struct TurnContext: Sendable {
    let text: String
    let policy: RoutePolicy
    let system: String
    let now: Date
}

/// Orchestrates one turn: save the raw note, ask the model, apply its tool calls, and recover.
/// Recovery order: repair once on the same route, escalate to cloud (auto policy only), then keep the note.
public actor Assistant {
    private let ontology: Ontology
    private let store: any GraphStore
    private let executor: ToolExecutor
    private let model: any ModelAdapter
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(ontology: Ontology, store: any GraphStore, model: any ModelAdapter,
                clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.ontology = ontology
        self.store = store
        self.executor = ToolExecutor(ontology: ontology, store: store)
        self.model = model
        self.clock = clock
        self.timeZone = timeZone
    }

    public func handle(_ text: String, policy: RoutePolicy) async throws -> AssistantTurn {
        let now = clock()
        let noteId = UUID().uuidString.lowercased()
//        try await store.apply([.upsert(DynamicNode(id: noteId, className: "Note", props: Self.noteProps(text, now: now)))])

        let ctx = TurnContext(text: text,
                              policy: policy,
                              system: try await systemPrompt(noteId: noteId, now: now), now: now)

        var current = try await askAndApply(text, policy: policy, in: ctx)
        current = await answerReadQuery(current, in: ctx)
        current = await repairRejected(current, in: ctx)
        current = await escalateIfNeeded(current, in: ctx)

        return try await finish(current, in: ctx, noteId: noteId)
    }

    // MARK: turn steps

    /// Step 1: One model call followed by the executor on its reply. Nil when the model call failed.
    private func askAndApply(_ user: String, policy: RoutePolicy, in ctx: TurnContext) async throws -> Attempt {
        let reply = try await ask(user, policy, system: ctx.system)
        let outcome = await executor.run(reply: reply.text, now: ctx.now)
        return Attempt(reply: reply, outcome: outcome)
    }

    /// Step 2: Reviewer step. Read answer needs one more model call that sees the results. A failed call keeps the first answer.
    private func answerReadQuery(_ first: Attempt, in ctx: TurnContext) async -> Attempt {
        guard first.outcome.committed, !first.outcome.results.isEmpty else { return first }
        let results = JSONValue.array(first.outcome.results).jsonString
        let followUp = "TOOL RESULTS: \(results)\nAnswer the user's message now. Reply with the JSON object; calls may be empty."
        return (try? await askAndApply(followUp, policy: ctx.policy, in: ctx)) ?? first
    }

    /// Step 3: a rejected reply gets one repair call, shown the validation reasons. A failed call keeps the rejected answer.
    private func repairRejected(_ current: Attempt, in ctx: TurnContext) async -> Attempt {
        guard !current.outcome.committed else { return current }
        let reasons = current.outcome.issues.joined(separator: "; ")
        let repair = "Your reply was rejected: \(reasons). Reply again with only a corrected JSON object for this message: \(ctx.text)"
        return (try? await askAndApply(repair, policy: ctx.policy, in: ctx)) ?? current
    }

    /// Step 4: under the auto policy, escalate once to cloud when the on-device answer was rejected or silent on a to-do.
    private func escalateIfNeeded(_ current: Attempt, in ctx: TurnContext) async -> Attempt {
        guard ctx.policy == .auto, current.reply.route != .cloud, needsCloud(current, text: ctx.text) else {
            return current
        }
        return (try? await askAndApply(ctx.text, policy: .forceCloud, in: ctx)) ?? current
    }

    /// Step 5: turns the final attempt into what the chat shows. Never claims a task that was not stored.
    private func finish(_ final: Attempt, in ctx: TurnContext, noteId: String) async throws -> AssistantTurn {
        let label = Self.label(final.reply, policy: ctx.policy)
        guard final.outcome.committed else { return savedOnlyTurn(label: label, noteId: noteId) }

        let after = try await store.read()
        let proposals: [TaskProposal] = final.outcome.changedIds.sorted().compactMap { id in
            guard let node = after.nodes[id], node.className == "Task", node.status == "proposed" else { return nil }
            return TaskProposal(id: id, title: node.title)
        }
//        // A to-do that wrote nothing is saved-only. A note that was written is a success, even without a Task.
//        if proposals.isEmpty, final.outcome.changedIds.isEmpty, Self.looksActionable(ctx.text) {
//            return savedOnlyTurn(label: label, noteId: noteId)
//        }
        let say = final.outcome.say.isEmpty ? "Saved." : final.outcome.say
        return AssistantTurn(say: say, routeLabel: label, proposals: proposals, noteId: noteId, savedOnly: false)
    }

    // MARK: turn helpers

    private func systemPrompt(noteId: String, now: Date) async throws -> String {
        let snapshot = try await store.read()
        return SystemPrompt.system(ontology: ontology, now: now, timeZone: timeZone,
                                   digest: Digest.build(snapshot), noteId: noteId)
    }

    /// Escalation is needed when the batch was rejected, or when on-device wrote nothing for a message that asks for something.
    private func needsCloud(_ attempt: Attempt, text: String) -> Bool {
        if !attempt.outcome.committed { return true }
        let silentOnDevice = attempt.outcome.changedIds.isEmpty && attempt.reply.route == .onDevice
        return silentOnDevice && Self.looksActionable(text)
    }

    private func savedOnlyTurn(label: String, noteId: String) -> AssistantTurn {
        AssistantTurn(say: "Saved your message as a note. I couldn't turn it into tasks.",
                      routeLabel: label, proposals: [], noteId: noteId, savedOnly: true)
    }

    /// Accepts a proposed task: it becomes active and, if it has a due time, gets a reminder.
    public func accept(taskId: String, reminders: (any RemindersAdapter)?) async throws {
        let snap = try await store.read()
        guard var node = snap.nodes[taskId], node.className == "Task" else { return }
        node.props["status"] = .string("active")
        node.props["updated_at"] = .string(ISO8601DateFormatter().string(from: clock()))
        if let reminders, let dueText = node.props["due"]?.stringValue,
           let due = DateParsing.parse(dueText, in: timeZone), node.props["event_id"] == nil {
            let id = try await reminders.createReminder(title: node.title, due: due)
            node.props["event_id"] = .string(id)
        }
        try await store.apply([.upsert(node)])
    }

    public func dismiss(taskId: String) async throws {
        let snap = try await store.read()
        guard var node = snap.nodes[taskId], node.className == "Task" else { return }
        node.props["status"] = .string("dropped")
        try await store.apply([.upsert(node)])
    }

    // MARK: helpers

    /// One model call. A failure is nil so the flow can continue with the note already saved.
    private func ask(_ user: String, _ policy: RoutePolicy, system: String) async throws -> ModelReply {
        return try await model.generate(system: system, user: user, policy: policy)
    }

    static func noteProps(_ text: String, now: Date) -> [String: JSONValue] {
        let stamp = ISO8601DateFormatter().string(from: now)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let title = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        return ["title": .string(title), "body": .string(text), "kind": .string("thought"),
                "status": .string("active"), "created_at": .string(stamp), "updated_at": .string(stamp)]
    }

    /// Cheap cue for "this asks for a task or reminder". Used only to decide on escalation.
    static func looksActionable(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return false }
        let cues = ["remind", "remember to", "need to", "have to", "todo", "to-do", "don't forget", "call ", "buy ",
                    "schedule", "book ", "send ", "pay ", "email ", "tomorrow", "today", "monday", "tuesday",
                    "wednesday", "thursday", "friday", "saturday", "sunday", " am", " pm", ":00", "o'clock"]
        return cues.contains { lower.contains($0) }
    }

    static func label(_ reply: ModelReply, policy: RoutePolicy) -> String {
        let place: String
        switch reply.route {
        case .onDevice: place = "On-device"
        case .cloud: place = policy == .forceCloud ? "Cloud (forced)" : "Cloud"
        }
        return "\(place) · \(String(format: "%.1f", reply.seconds)) s"
    }
}
