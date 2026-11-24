import AgentKit
import Foundation

// Purpose: model processing for each step of the `intent` graph. A step reads the state it is given, calls the
// model or the store, and returns the actions it produced. It never changes the state: `IntentReducer` does that.
//
// Testing: `IntentStepTests` runs each step's processing with a scripted model against an in-memory store, and
// checks the actions it returns (and, for writes, what the store holds).

/// Everything the intent steps use. `systems` holds one rendered system prompt per step.
nonisolated struct IntentEnv: Sendable {
    let model: any ModelAdapter
    let store: PocketStore
    let reminders: (any RemindersAdapter)?
    let timeZone: TimeZone
    let systems: [PromptRole: String]
}

nonisolated enum IntentSteps {
    /// Model processing for one step. Gates are checked by the caller, before this runs.
    static func process(_ step: IntentStep, _ state: IntentTurnState, env: IntentEnv) async -> [IntentAction] {
        switch step {
        case .classify:
            return [.classified(.classify, await classifyCall(state.text, role: .intentClassify, policy: state.policy, env: env))]

        case .repair:
            let user = "Your reply was not a JSON object with intents. Reply again with only {\"intents\":[...]} for this message: \(state.text)"
            return [.classified(.repair, await classifyCall(user, role: .intentClassifyRepair, policy: state.policy, env: env))]

        case .escalate:
            return [.classified(.escalate, await classifyCall(state.text, role: .intentClassify, policy: .forceCloud, env: env))]

        case .fallback:
            return [.fellBack]

        case .saveNote:
            do {
                try await saveNote(state, env: env)
                return [.noteSaved(say: nil)]
            } catch {
                return [.noteFailed(error.localizedDescription)]
            }

        case .extractTask:
            return await extractTaskActions(state, env: env)

        case .answer:
            return await answerActions(state, env: env)

        case .followUp:
            return [await followUpAction(state, env: env)]

        case .clarify:
            return [await clarifyAction(state, env: env)]
        }
    }

    // MARK: classifier

    /// One classifier call. A reply without a valid `intents` list counts as a failure.
    private static func classifyCall(_ user: String, role: PromptRole, policy: RoutePolicy, env: IntentEnv) async -> ClassifyResult {
        guard let reply = try? await env.model.generate(system: env.systems.prompt(role), user: user, policy: policy) else {
            return ClassifyResult(ok: false, intents: [], route: "")
        }
        let label = Assistant.label(reply, policy: policy)
        guard let parsed = IntentParser.parse(reply.text) else { return ClassifyResult(ok: false, intents: [], route: label) }
        return ClassifyResult(ok: true, intents: parsed, route: label)
    }

    // MARK: note

    /// Writes the message as a Note. Code only: the model is not involved.
    private static func saveNote(_ state: IntentTurnState, env: IntentEnv) async throws {
        let firstLine = state.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? state.text
        let title = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        try await env.store.saveNote(id: state.noteId, title: title, body: state.text, now: state.now)
    }

    // MARK: tasks

    private struct TaskOutcome {
        var taskIds: [String] = []
        var reminderFailed = false
        var route = ""
        var say: String?
    }

    /// Task step: one call, then one repair, then one cloud escalation under the auto policy.
    /// If no task is created, the message is kept as a note (fallback actions), so nothing the user said is lost.
    private static func extractTaskActions(_ state: IntentTurnState, env: IntentEnv) async -> [IntentAction] {
        let outcome = await extractTasks(state, env: env)
        if !outcome.taskIds.isEmpty {
            return [.tasksCreated(ids: outcome.taskIds, route: outcome.route, say: outcome.say,
                                  reminderFailed: outcome.reminderFailed)]
        }
        var actions: [IntentAction] = [.taskFailed(route: outcome.route, say: outcome.say)]
        if !state.noteDone {
            do {
                try await saveNote(state, env: env)
                actions.append(.noteSaved(say: "I couldn't turn that into a task, so I saved it as a note."))
            } catch {
                actions.append(.noteFailed(error.localizedDescription))
            }
        }
        return actions
    }

    /// Tasks are created active by the executor. Each one with a due time then gets a reminder, and the
    /// reminder's id is stored on the task object.
    private static func extractTasks(_ state: IntentTurnState, env: IntentEnv) async -> TaskOutcome {
        let executor = ToolExecutor(store: env.store, timeZone: env.timeZone,
                                    allowedTools: ["remember"], allowedTypes: ["Task"])
        var committed: (attempt: Attempt, label: String)?
        var issues: [String] = []
        for step in 0..<3 {
            if step == 2, state.policy != .auto { break }
            let policy: RoutePolicy = step == 2 ? .forceCloud : state.policy
            let user = step == 0
                ? state.text
                : "Your reply was rejected: \(issues.isEmpty ? "no valid reply" : issues.joined(separator: "; ")). Reply again with only a corrected JSON object for this message: \(state.text)"
            let role = step == 0 ? PromptRole.intentTask : PromptRole.intentTaskRepair
            guard let attempt = try? await runAttempt(user, system: env.systems.prompt(role), policy: policy, now: state.now,
                                                      model: env.model, executor: executor) else { continue }
            let label = Assistant.label(attempt.reply, policy: policy)
            if attempt.outcome.committed {
                committed = (attempt, label)
                break
            }
            issues = attempt.outcome.issues
        }
        guard let committed else { return TaskOutcome(route: "") }

        var outcome = TaskOutcome(route: committed.label)
        for id in committed.attempt.outcome.changedIds {
            guard let task = try? await env.store.task(id: id) else { continue }
            outcome.taskIds.append(id)
            guard let reminders = env.reminders, let due = task.due, task.eventId == nil else { continue }
            do {
                let eventId = try await reminders.createReminder(title: task.title, due: due)
                try await env.store.setEventId(eventId, taskId: id)
            } catch {
                outcome.reminderFailed = true
            }
        }

        let modelSay = committed.attempt.outcome.say
        var say = modelSay.isEmpty ? (state.noteDone ? "Saved your note and added a task." : "Added a task.") : modelSay
        if outcome.reminderFailed { say += " Reminder not created." }
        outcome.say = say
        return outcome
    }

    // MARK: answers

    /// Answer step: read tools only. The results are returned so the follow-up step can answer from them.
    /// A rejected reply is asked again once, with the reasons. If the second reply is also rejected, the turn
    /// goes to the clarify step, which writes nothing.
    private static func answerActions(_ state: IntentTurnState, env: IntentEnv) async -> [IntentAction] {
        let executor = ToolExecutor(store: env.store, timeZone: env.timeZone, allowedTools: ["recall", "due"])
        var issues: [String] = []
        var last: Attempt?
        for step in 0..<2 {
            let user = step == 0
                ? state.text
                : "Your reply was rejected: \(issues.joined(separator: "; ")). Reply again with one JSON object for this message: \(state.text)"
            guard let attempt = try? await runAttempt(user, system: env.systems.prompt(.intentAnswer), policy: state.policy,
                                                      now: state.now, model: env.model, executor: executor) else {
                return [.answerUnavailable]
            }
            if attempt.outcome.committed {
                return [.answered(route: Assistant.label(attempt.reply, policy: state.policy), results: attempt.outcome.results,
                                  say: attempt.outcome.say, committed: true)]
            }
            issues = attempt.outcome.issues
            last = attempt
        }
        guard let last else { return [.answerUnavailable] }
        return [.answered(route: Assistant.label(last.reply, policy: state.policy), results: [], say: "", committed: false)]
    }

    /// Follow-up: answers from the results of the read the model just ran. Writes nothing.
    private static func followUpAction(_ state: IntentTurnState, env: IntentEnv) async -> IntentAction {
        let executor = ToolExecutor(store: env.store, timeZone: env.timeZone, allowedTools: ["recall", "due"])
        let results = JSONValue.array(state.results).jsonString
        let user = "TOOL RESULTS: \(results)\nAnswer the user's message now. Reply with the JSON object; calls may be empty."
        if let attempt = try? await runAttempt(user, system: env.systems.prompt(.intentAnswerFollowUp), policy: state.policy,
                                               now: state.now, model: env.model, executor: executor),
           attempt.outcome.committed, !attempt.outcome.say.isEmpty {
            return .followedUp(say: attempt.outcome.say)
        }
        return .followedUp(say: nil)
    }

    /// Clarify: chat, greetings and unclear messages get one tool-free reply. Nil means the fixed question is used.
    private static func clarifyAction(_ state: IntentTurnState, env: IntentEnv) async -> IntentAction {
        let executor = ToolExecutor(store: env.store, timeZone: env.timeZone, allowedTools: [])
        if let attempt = try? await runAttempt(state.text, system: env.systems.prompt(.intentClarify), policy: state.policy,
                                               now: state.now, model: env.model, executor: executor),
           attempt.outcome.committed, !attempt.outcome.say.isEmpty {
            return .clarified(say: attempt.outcome.say, route: Assistant.label(attempt.reply, policy: state.policy))
        }
        return .clarified(say: nil, route: "")
    }
}
