import Foundation

// Purpose: the app state of one `intent` turn, handled Redux-style.
//
// - `IntentTurnState` is the single state of a turn. Nothing else holds turn data.
// - `IntentAction` is what a step reports after its model processing (a parsed reply, a store write, a failure).
// - `IntentGate.input` is the INPUT gatekeeper: it checks the state a step is about to run on. A step with a
//   failing gate does not run, and the router never sends the turn to it.
// - `IntentReducer.reduce` is the OUTPUT gatekeeper and the only code that changes the state. It refuses an action
//   that breaks its step's contract: the state is left as it was, and the refusal is recorded in `rejections`.
// - `IntentStore` is the Redux-style container: it dispatches actions through the reducer and logs them.
//
// Testing approach, one suite per step (see IntentStepTests.swift):
//   1. input gate: the state a step needs passes, and states it must not run on are refused;
//   2. model processing: the step, with a scripted model, produces the expected actions;
//   3. output gate: the reducer applies valid actions to the state, and refuses invalid ones.

/// One step of the `intent` graph. The raw value is the node name in the graph.
nonisolated enum IntentStep: String, Sendable, CaseIterable {
    case classify, repair, escalate, fallback
    case saveNote, extractTask
    case answer, followUp, clarify
}

/// What the classifier returned for one attempt. `ok` is false when no valid `intents` object came back.
nonisolated struct ClassifyResult: Sendable, Equatable {
    let ok: Bool
    let intents: Set<Intent>
    let route: String
}

/// The state of one turn, carried through the graph.
nonisolated struct IntentTurnState: Sendable {
    let text: String
    let policy: RoutePolicy
    let now: Date
    let noteId: String
    var intents: Set<Intent> = []
    var classifyOK = false
    var classifyRepairs = 0
    var escalated = false
    var classifyFailed = false
    var noteDone = false
    var actionDone = false
    var answered = false
    var followedUp = false
    var results: [JSONValue] = []
    var taskIds: [String] = []
    var reminderFailed = false
    var say = ""
    var route = ""
    /// Set when the answer step could not answer, so the message goes to the clarify step.
    var clarifyNeeded = false
    /// Every action the output gate refused, as "step: reason". Empty when the turn kept its contracts.
    var rejections: [String] = []
}

/// What a step reports. Produced by model processing; applied only through the reducer.
nonisolated enum IntentAction: Sendable, Equatable {
    case classified(IntentStep, ClassifyResult)
    case fellBack
    /// `say` overrides the default reply when given.
    case noteSaved(say: String?)
    case noteFailed(String)
    case tasksCreated(ids: [String], route: String, say: String?, reminderFailed: Bool)
    case taskFailed(route: String, say: String?)
    case answered(route: String, results: [JSONValue], say: String, committed: Bool)
    case answerUnavailable
    /// `say` is nil when the follow-up produced no usable answer.
    case followedUp(say: String?)
    /// `say` is nil when the clarify model call failed; the fixed question is used then.
    case clarified(say: String?, route: String)
    /// The input gate refused the step before it ran.
    case rejected(IntentStep, [String])

    /// The step this action belongs to.
    var step: IntentStep {
        switch self {
        case .classified(let step, _), .rejected(let step, _): step
        case .fellBack: .fallback
        case .noteSaved, .noteFailed: .saveNote
        case .tasksCreated, .taskFailed: .extractTask
        case .answered, .answerUnavailable: .answer
        case .followedUp: .followUp
        case .clarified: .clarify
        }
    }
}

// MARK: - Input gatekeeper

/// Checks the state before a step runs. Returns the problems; an empty list means the step may run.
nonisolated enum IntentGate {
    static func input(_ step: IntentStep, _ s: IntentTurnState) -> [String] {
        var problems: [String] = []
        func require(_ ok: Bool, _ why: String) {
            if !ok { problems.append(why) }
        }
        switch step {
        case .classify:
            require(!s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the message is empty")
            require(s.classifyRepairs == 0 && !s.escalated, "the classifier already ran")
        case .repair:
            require(!s.classifyOK, "the classifier already succeeded")
            require(s.classifyRepairs == 0, "the repair already ran")
        case .escalate:
            require(!s.classifyOK, "the classifier already succeeded")
            require(s.classifyRepairs == 1, "escalation comes after one repair")
            require(s.policy == .auto, "escalation needs the auto policy")
            require(!s.escalated, "the message was already escalated")
        case .fallback:
            require(!s.classifyOK, "the classifier succeeded")
            require(s.classifyRepairs > 0, "the classifier has not been asked again")
            require(s.escalated || s.policy != .auto, "the classifier can still be escalated")
        case .saveNote:
            require(s.intents.contains(.note), "the message has no note intent")
            require(!s.noteDone, "the note is already saved")
        case .extractTask:
            require(s.intents.contains(.task), "the message has no task intent")
            require(!s.actionDone, "the task step already ran")
        case .answer:
            require(s.intents.contains(.discuss), "the message is not a question or chat")
            require(!s.answered, "the answer step already ran")
        case .followUp:
            require(s.answered, "the answer step has not run")
            require(!s.results.isEmpty, "there are no read results to answer from")
            require(!s.followedUp, "the follow-up already ran")
        case .clarify:
            require(s.intents.contains(.unclear) || s.classifyFailed || s.clarifyNeeded, "nothing needs a question")
        }
        return problems
    }

    /// The next step for a turn that has finished its classifier: the first write or answer step still owed.
    static func next(_ s: IntentTurnState) -> IntentStep? {
        if s.intents.contains(.note), input(.saveNote, s).isEmpty { return .saveNote }
        if s.intents.contains(.task), input(.extractTask, s).isEmpty { return .extractTask }
        if s.intents.contains(.discuss), input(.answer, s).isEmpty { return .answer }
        if s.intents.contains(.unclear), input(.clarify, s).isEmpty { return .clarify }
        return nil
    }

    /// The intents a message may carry: a write (note and/or task), or exactly one of discuss and unclear.
    static func validIntents(_ intents: Set<Intent>) -> Bool {
        if intents.isEmpty { return false }
        if !intents.intersection([.note, .task]).isEmpty {
            return intents.isDisjoint(with: [.discuss, .unclear])
        }
        return intents == [.discuss] || intents == [.unclear]
    }
}

// MARK: - Output gatekeeper

/// The only code that changes an `IntentTurnState`. Each action is checked against the state it is applied to.
nonisolated enum IntentReducer {
    static func reduce(_ state: IntentTurnState, _ action: IntentAction) -> IntentTurnState {
        var s = state
        let step = action.step
        switch action {
        case .rejected(_, let problems):
            s.rejections += problems.map { "\(step.rawValue): \($0)" }

        case .classified(_, let r):
            if r.ok, !IntentGate.validIntents(r.intents) {
                return refuse(state, step, "intents \(r.intents.map(\.rawValue).sorted()) break the combination rules")
            }
            s.classifyOK = r.ok
            if r.ok { s.intents = r.intents }
            switch step {
            case .repair:
                s.classifyRepairs += 1
                if !r.route.isEmpty { s.route = r.route }
            case .escalate:
                s.escalated = true
                if !r.route.isEmpty { s.route = r.route }
            default:
                s.route = r.route
            }

        case .fellBack:
            if s.classifyOK { return refuse(state, step, "the classifier already succeeded") }
            s.classifyFailed = true

        case .noteSaved(let say):
            if !(s.intents.contains(.note) || s.actionDone) { return refuse(state, step, "no note was asked for") }
            if s.noteDone { return refuse(state, step, "the note is already saved") }
            s.noteDone = true
            if let say {
                s.say = say
            } else if !s.intents.contains(.task) {
                s.say = s.classifyFailed
                    ? "I couldn't tell what you wanted, so I saved it as a note."
                    : "Saved your note."
            }

        case .noteFailed(let message):
            if !(s.intents.contains(.note) || s.actionDone) { return refuse(state, step, "no note was asked for") }
            if s.noteDone { return refuse(state, step, "the note is already saved") }
            s.noteDone = true
            s.say = "Couldn't save your note: \(message)"

        case .tasksCreated(let ids, let route, let say, let reminderFailed):
            if !s.intents.contains(.task) { return refuse(state, step, "the message has no task intent") }
            if s.actionDone { return refuse(state, step, "the task step already ran") }
            if ids.isEmpty { return refuse(state, step, "no task was created") }
            s.actionDone = true
            s.route = route
            s.taskIds = ids
            s.reminderFailed = reminderFailed
            if let say { s.say = say }

        case .taskFailed(let route, let say):
            if !s.intents.contains(.task) { return refuse(state, step, "the message has no task intent") }
            if s.actionDone { return refuse(state, step, "the task step already ran") }
            s.actionDone = true
            s.route = route
            if let say { s.say = say }

        case .answered(let route, let results, let say, let committed):
            if !s.intents.contains(.discuss) { return refuse(state, step, "the message is not a question or chat") }
            if s.answered { return refuse(state, step, "the answer step already ran") }
            s.answered = true
            s.route = route
            s.results = results
            if committed {
                s.say = say.isEmpty ? "Here is what I found." : say
            } else {
                s.clarifyNeeded = true
            }

        case .answerUnavailable:
            if !s.intents.contains(.discuss) { return refuse(state, step, "the message is not a question or chat") }
            if s.answered { return refuse(state, step, "the answer step already ran") }
            s.answered = true
            s.say = "I couldn't answer that right now."

        case .followedUp(let say):
            if !s.answered { return refuse(state, step, "the answer step has not run") }
            if s.results.isEmpty { return refuse(state, step, "there are no read results to answer from") }
            if s.followedUp { return refuse(state, step, "the follow-up already ran") }
            s.followedUp = true
            if let say { s.say = say }

        case .clarified(let say, let route):
            if !(s.intents.contains(.unclear) || s.classifyFailed || s.clarifyNeeded) {
                return refuse(state, step, "nothing needs a question")
            }
            s.say = say ?? "Do you want me to save that as a note, or set a task?"
            if !route.isEmpty { s.route = route }
        }
        return s
    }

    /// Leaves the state as it was and records why the action was refused.
    private static func refuse(_ state: IntentTurnState, _ step: IntentStep, _ why: String) -> IntentTurnState {
        var s = state
        s.rejections.append("\(step.rawValue): \(why)")
        return s
    }
}

// MARK: - Redux-style container

/// Holds a turn's state and applies every action through the reducer, keeping the sequence of actions.
nonisolated struct IntentStore: Sendable {
    private(set) var state: IntentTurnState
    /// Every dispatched action, in order.
    private(set) var log: [IntentAction] = []

    init(_ state: IntentTurnState) { self.state = state }

    mutating func dispatch(_ action: IntentAction) {
        state = IntentReducer.reduce(state, action)
        log.append(action)
    }
}
