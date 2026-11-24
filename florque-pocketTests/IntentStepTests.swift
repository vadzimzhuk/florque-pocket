import Foundation
import Testing
@testable import florque_pocket

// Purpose: tests each step of the `intent` graph in three phases, in the order the turn runs them:
//   1. input gate (IntentInputGateTests): the state a step runs on is valid, and invalid states are refused;
//   2. model processing (IntentStepTests): with a scripted model and a memory store, the step produces the actions;
//   3. output gate (IntentReducerTests): the reducer applies each action, and refuses the ones that break the contract.
//
// Testing approach: the gates and the reducer are pure functions, so they are tested on literal states. Model
// processing is tested with `FakeModel` (scripted replies) and an in-memory `PocketStore`.

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

/// A fresh turn state for one message, with optional changes applied.
private func state(_ text: String = "I have a meeting with Anna on Monday.", policy: RoutePolicy = .auto,
                   _ configure: (inout IntentTurnState) -> Void = { _ in }) -> IntentTurnState {
    var s = IntentTurnState(text: text, policy: policy, now: t0, noteId: "n-1")
    configure(&s)
    return s
}

/// The environment the steps run in: the scripted model, a store, optional reminders, and the real step prompts.
@MainActor
private func env(_ model: FakeModel, store: PocketStore, reminders: (any RemindersAdapter)? = nil) -> IntentEnv {
    let context = PromptContext(now: t0, timeZone: utc, digest: "none", noteId: "n-1")
    return IntentEnv(model: model, store: store, reminders: reminders, timeZone: utc,
                     systems: IntentPromptFactory().renderAll(.current, context))
}

private func classifyResult(_ actions: [IntentAction]) -> ClassifyResult? {
    guard case .classified(_, let result)? = actions.first else { return nil }
    return result
}

// MARK: - 1. Input gatekeeper

@Suite struct IntentInputGateTests {
    @Test func classifyNeedsANonEmptyMessageAndRunsOnce() {
        #expect(IntentGate.input(.classify, state()).isEmpty)
        #expect(!IntentGate.input(.classify, state("   ")).isEmpty)
        #expect(!IntentGate.input(.classify, state { $0.classifyRepairs = 1 }).isEmpty)
    }

    @Test func repairRunsOnlyAfterAFailedClassifier() {
        #expect(IntentGate.input(.repair, state()).isEmpty)
        #expect(!IntentGate.input(.repair, state { $0.classifyOK = true }).isEmpty)
        #expect(!IntentGate.input(.repair, state { $0.classifyRepairs = 1 }).isEmpty)
    }

    @Test func escalateNeedsOneRepairAndTheAutoPolicy() {
        #expect(IntentGate.input(.escalate, state { $0.classifyRepairs = 1 }).isEmpty)
        #expect(!IntentGate.input(.escalate, state()).isEmpty, "no repair yet")
        #expect(!IntentGate.input(.escalate, state(policy: .forceOnDevice) { $0.classifyRepairs = 1 }).isEmpty)
        #expect(!IntentGate.input(.escalate, state { $0.classifyRepairs = 1; $0.escalated = true }).isEmpty)
    }

    @Test func fallbackRunsOnlyWhenTheClassifierCannotBeRetried() {
        #expect(IntentGate.input(.fallback, state { $0.classifyRepairs = 1; $0.escalated = true }).isEmpty)
        #expect(IntentGate.input(.fallback, state(policy: .forceOnDevice) { $0.classifyRepairs = 1 }).isEmpty)
        #expect(!IntentGate.input(.fallback, state { $0.classifyRepairs = 1 }).isEmpty, "auto can still escalate")
        #expect(!IntentGate.input(.fallback, state { $0.classifyOK = true; $0.classifyRepairs = 1; $0.escalated = true }).isEmpty)
    }

    @Test func saveNoteNeedsANoteIntentAndRunsOnce() {
        #expect(IntentGate.input(.saveNote, state { $0.intents = [.note] }).isEmpty)
        #expect(!IntentGate.input(.saveNote, state { $0.intents = [.task] }).isEmpty)
        #expect(!IntentGate.input(.saveNote, state { $0.intents = [.note]; $0.noteDone = true }).isEmpty)
    }

    @Test func extractTaskNeedsATaskIntentAndRunsOnce() {
        #expect(IntentGate.input(.extractTask, state { $0.intents = [.task] }).isEmpty)
        #expect(!IntentGate.input(.extractTask, state { $0.intents = [.note] }).isEmpty)
        #expect(!IntentGate.input(.extractTask, state { $0.intents = [.task]; $0.actionDone = true }).isEmpty)
    }

    @Test func answerNeedsDiscussAndRunsOnce() {
        #expect(IntentGate.input(.answer, state { $0.intents = [.discuss] }).isEmpty)
        #expect(!IntentGate.input(.answer, state { $0.intents = [.task] }).isEmpty)
        #expect(!IntentGate.input(.answer, state { $0.intents = [.discuss]; $0.answered = true }).isEmpty)
    }

    @Test func followUpNeedsReadResultsAndRunsOnce() {
        let results: [JSONValue] = [.object(["id": .string("t-1")])]
        #expect(IntentGate.input(.followUp, state { $0.answered = true; $0.results = results }).isEmpty)
        #expect(!IntentGate.input(.followUp, state { $0.answered = true }).isEmpty, "no results")
        #expect(!IntentGate.input(.followUp, state { $0.results = results }).isEmpty, "the answer step has not run")
        #expect(!IntentGate.input(.followUp, state { $0.answered = true; $0.results = results; $0.followedUp = true }).isEmpty)
    }

    @Test func clarifyNeedsAnUnclearMessageOrAFailedClassifier() {
        #expect(IntentGate.input(.clarify, state { $0.intents = [.unclear] }).isEmpty)
        #expect(IntentGate.input(.clarify, state { $0.classifyFailed = true }).isEmpty)
        #expect(IntentGate.input(.clarify, state { $0.clarifyNeeded = true }).isEmpty)
        #expect(!IntentGate.input(.clarify, state { $0.intents = [.discuss] }).isEmpty)
    }

    /// The router only goes to a step whose gate passes, in this order: note, task, question, unclear.
    @Test func nextStepFollowsTheGates() {
        #expect(IntentGate.next(state { $0.intents = [.note, .task] }) == .saveNote)
        #expect(IntentGate.next(state { $0.intents = [.note, .task]; $0.noteDone = true }) == .extractTask)
        #expect(IntentGate.next(state { $0.intents = [.note, .task]; $0.noteDone = true; $0.actionDone = true }) == nil)
        #expect(IntentGate.next(state { $0.intents = [.discuss] }) == .answer)
        #expect(IntentGate.next(state { $0.intents = [.unclear] }) == .clarify)
        #expect(IntentGate.next(state()) == nil, "no classified intent: nothing to run")
    }

    @Test func intentCombinationsFollowTheRules() {
        #expect(IntentGate.validIntents([.note, .task]))
        #expect(IntentGate.validIntents([.discuss]))
        #expect(IntentGate.validIntents([.unclear]))
        #expect(!IntentGate.validIntents([.note, .discuss]))
        #expect(!IntentGate.validIntents([.unclear, .discuss]))
        #expect(!IntentGate.validIntents([]))
    }
}

// MARK: - 2. Model processing

@MainActor @Suite struct IntentStepTests {
    @Test func classifyParsesAValidReply() async throws {
        let model = FakeModel([(#"{"intents":["note","task"]}"#, .onDevice)])
        let actions = await IntentSteps.process(.classify, state(), env: env(model, store: try makeMemoryStore()))
        let result = try #require(classifyResult(actions))
        #expect(result.ok)
        #expect(result.intents == [.note, .task])
        #expect(!result.route.isEmpty, "the route label is kept for the chat")
    }

    @Test func classifyReportsAnUnparsableReplyAsFailed() async throws {
        let model = FakeModel([("Sorry, I can't.", .onDevice)])
        let actions = await IntentSteps.process(.classify, state(), env: env(model, store: try makeMemoryStore()))
        let result = try #require(classifyResult(actions))
        #expect(!result.ok)
        #expect(result.intents.isEmpty)
    }

    @Test func classifyReportsAModelErrorAsFailedWithoutARoute() async throws {
        let model = FakeModel([])
        let actions = await IntentSteps.process(.classify, state(), env: env(model, store: try makeMemoryStore()))
        #expect(classifyResult(actions) == ClassifyResult(ok: false, intents: [], route: ""))
    }

    @Test func repairAsksForTheClassifierObjectAgain() async throws {
        let model = FakeModel([(#"{"intents":["discuss"]}"#, .onDevice)])
        let actions = await IntentSteps.process(.repair, state { $0.classifyRepairs = 0 },
                                                env: env(model, store: try makeMemoryStore()))
        #expect(actions.first?.step == .repair)
        #expect(classifyResult(actions)?.intents == [.discuss])
        #expect(await model.calls.last?.user.contains("Your reply was not a JSON object") == true)
    }

    @Test func escalateClassifiesInTheCloud() async throws {
        let model = FakeModel([(#"{"intents":["unclear"]}"#, .cloud)])
        _ = await IntentSteps.process(.escalate, state { $0.classifyRepairs = 1 }, env: env(model, store: try makeMemoryStore()))
        #expect(await model.calls.last?.policy == .forceCloud)
    }

    @Test func fallbackOnlyMarksTheFailure() async throws {
        let actions = await IntentSteps.process(.fallback, state(), env: env(FakeModel([]), store: try makeMemoryStore()))
        #expect(actions == [.fellBack])
    }

    @Test func saveNoteWritesTheMessageAsANote() async throws {
        let store = try makeMemoryStore()
        let actions = await IntentSteps.process(.saveNote, state { $0.intents = [.note] }, env: env(FakeModel([]), store: store))
        #expect(actions == [.noteSaved(say: nil)])
        let note = try #require(try await store.recentNotes(limit: 10).first)
        #expect(note.id == "n-1")
        #expect(note.body == "I have a meeting with Anna on Monday.")
        #expect(note.title == "I have a meeting with Anna on Monday.")
    }

    @Test func extractTaskCreatesTheTaskAndItsReminder() async throws {
        let store = try makeMemoryStore()
        let reminders = await FakeReminders()
        let reply = #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Call the landlord","due":"2026-11-27T09:00:00"}}],"say":"Reminder set."}"#
        let actions = await IntentSteps.process(.extractTask, state("Call the landlord Friday at 9am.") { $0.intents = [.task] },
                                                env: env(FakeModel([(reply, .onDevice)]), store: store, reminders: reminders))
        guard case .tasksCreated(let ids, _, let say, let reminderFailed)? = actions.first else {
            Issue.record("expected tasksCreated, got \(actions)")
            return
        }
        #expect(ids.count == 1)
        #expect(say == "Reminder set.")
        #expect(!reminderFailed)
        #expect(await reminders.created.count == 1)
        #expect(try await store.task(id: ids[0])?.eventId == "ek-1")
    }

    /// Three rejected replies (the step, its repair, and the cloud escalation): the message is kept as a note.
    @Test func extractTaskKeepsTheMessageAsANoteWhenNoTaskIsCreated() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([("nope", .onDevice), ("nope", .onDevice), ("nope", .cloud)])
        let actions = await IntentSteps.process(.extractTask, state { $0.intents = [.task] }, env: env(model, store: store))
        #expect(actions.count == 2)
        #expect(actions.first == .taskFailed(route: "", say: nil))
        #expect(actions.last == .noteSaved(say: "I couldn't turn that into a task, so I saved it as a note."))
        #expect(try await store.recentNotes(limit: 10).count == 1)
        #expect(try await store.openTasks().isEmpty)
    }

    @Test func answerReadsTheStoreThroughRecall() async throws {
        let store = try makeMemoryStore()
        try await store.addTasks([NewTask(id: "t-1", title: "Call the landlord", due: nil, about: nil)], now: t0)
        let reply = #"{"calls":[{"tool":"recall","args":{"text":"landlord"}}],"say":""}"#
        let actions = await IntentSteps.process(.answer, state("What is on my list?") { $0.intents = [.discuss] },
                                                env: env(FakeModel([(reply, .onDevice)]), store: store))
        guard case .answered(_, let results, _, let committed)? = actions.first else {
            Issue.record("expected answered, got \(actions)")
            return
        }
        #expect(committed)
        #expect(results.count == 1)
        #expect(try await store.openTasks().count == 1, "answering writes nothing")
    }

    @Test func answerReportsAModelErrorAsUnavailable() async throws {
        let actions = await IntentSteps.process(.answer, state { $0.intents = [.discuss] },
                                                env: env(FakeModel([]), store: try makeMemoryStore()))
        #expect(actions == [.answerUnavailable])
    }

    /// The reply reported from the device: the reply text was put in a made-up `say` tool, and the top-level
    /// `say` is missing. The executor must reject it with that reason.
    @Test func answerRejectsTheReportedReplyWithItsReason() async throws {
        let reported = #"{"calls":[{"tool":"recall","args":{"text":"Hi there"}},{"tool":"say","content":"Hello!"}]}"#
        let model = FakeModel([(reported, .onDevice), (reported, .onDevice)])
        let actions = await IntentSteps.process(.answer, state("Hi there") { $0.intents = [.discuss] },
                                                env: env(model, store: try makeMemoryStore()))
        guard case .answered(_, _, _, let committed)? = actions.first else {
            Issue.record("expected answered, got \(actions)")
            return
        }
        #expect(!committed, "a reply with an invented tool is not accepted")
        #expect(await model.calls.count == 2, "the answer step asks once more before giving up")
        #expect(await model.calls.last?.user.contains("call 2 (say): tool not allowed in this step") == true)
    }

    /// A rejected first reply is repaired by the second reply, which is then the answer.
    @Test func answerIsRepairedAfterARejectedReply() async throws {
        let reported = #"{"calls":[{"tool":"say","content":"Hello!"}]}"#
        let model = FakeModel([(reported, .onDevice), (#"{"calls":[],"say":"Hello!"}"#, .onDevice)])
        let actions = await IntentSteps.process(.answer, state("Hi there") { $0.intents = [.discuss] },
                                                env: env(model, store: try makeMemoryStore()))
        guard case .answered(_, _, let say, let committed)? = actions.first else {
            Issue.record("expected answered, got \(actions)")
            return
        }
        #expect(committed)
        #expect(say == "Hello!")
        #expect(await model.calls.count == 2)
    }

    @Test func followUpAnswersFromTheResults() async throws {
        let reply = #"{"calls":[],"say":"You have one task."}"#
        let results: [JSONValue] = [.object(["id": .string("t-1")])]
        let actions = await IntentSteps.process(.followUp, state { $0.answered = true; $0.results = results },
                                                env: env(FakeModel([(reply, .onDevice)]), store: try makeMemoryStore()))
        #expect(actions == [.followedUp(say: "You have one task.")])
    }

    @Test func followUpWithoutAUsableReplyLeavesTheAnswerAsIs() async throws {
        let results: [JSONValue] = [.object(["id": .string("t-1")])]
        let actions = await IntentSteps.process(.followUp, state { $0.answered = true; $0.results = results },
                                                env: env(FakeModel([("nope", .onDevice)]), store: try makeMemoryStore()))
        #expect(actions == [.followedUp(say: nil)])
    }

    @Test func clarifyReplesWithTheModelsQuestion() async throws {
        let reply = #"{"calls":[],"say":"Which time on Friday?"}"#
        let actions = await IntentSteps.process(.clarify, state { $0.intents = [.unclear] },
                                                env: env(FakeModel([(reply, .onDevice)]), store: try makeMemoryStore()))
        guard case .clarified(let say, let route)? = actions.first else {
            Issue.record("expected clarified, got \(actions)")
            return
        }
        #expect(say == "Which time on Friday?")
        #expect(!route.isEmpty)
    }

    @Test func clarifyWithoutAReplyUsesTheFixedQuestion() async throws {
        let actions = await IntentSteps.process(.clarify, state { $0.intents = [.unclear] },
                                                env: env(FakeModel([]), store: try makeMemoryStore()))
        #expect(actions == [.clarified(say: nil, route: "")])
    }

    /// The gate runs before the step: a refused step makes no model call and writes nothing.
    @Test func performRefusesAStepWhoseInputGateFails() async throws {
        let model = FakeModel([(#"{"calls":[],"say":"x"}"#, .onDevice)])
        let store = try makeMemoryStore()
        let result = await IntentWorkflow.perform(.saveNote, state { $0.intents = [.task] }, env: env(model, store: store))
        #expect(result.rejections == ["saveNote: the message has no note intent"])
        #expect(!result.noteDone)
        #expect(await model.calls.isEmpty)
        #expect(try await store.recentNotes(limit: 10).isEmpty)
    }
}

// MARK: - 3. Output gatekeeper (reducer)

@Suite struct IntentReducerTests {
    // classify, repair, escalate

    @Test func classifyAcceptsAValidClassification() {
        let s = IntentReducer.reduce(state(), .classified(.classify, ClassifyResult(ok: true, intents: [.note], route: "On-device")))
        #expect(s.classifyOK)
        #expect(s.intents == [.note])
        #expect(s.route == "On-device")
        #expect(s.rejections.isEmpty)
    }

    @Test func classifyRefusesACombinationTheRulesForbid() {
        let before = state()
        let s = IntentReducer.reduce(before, .classified(.classify, ClassifyResult(ok: true, intents: [.note, .discuss], route: "x")))
        #expect(s.rejections == ["classify: intents [\"discuss\", \"note\"] break the combination rules"])
        #expect(!s.classifyOK)
        #expect(s.intents.isEmpty)
    }

    @Test func classifyFailureKeepsTheIntentsItHad() {
        let s = IntentReducer.reduce(state { $0.intents = [.task] },
                                     .classified(.classify, ClassifyResult(ok: false, intents: [], route: "On-device")))
        #expect(!s.classifyOK)
        #expect(s.intents == [.task])
    }

    @Test func repairCountsTheAttemptAndKeepsARouteWhenItIsEmpty() {
        let s = IntentReducer.reduce(state { $0.route = "old" },
                                     .classified(.repair, ClassifyResult(ok: false, intents: [], route: "")))
        #expect(s.classifyRepairs == 1)
        #expect(s.route == "old")
    }

    @Test func escalateMarksTheMessageEscalated() {
        let s = IntentReducer.reduce(state { $0.classifyRepairs = 1 },
                                     .classified(.escalate, ClassifyResult(ok: true, intents: [.unclear], route: "Cloud")))
        #expect(s.escalated)
        #expect(s.intents == [.unclear])
        #expect(s.route == "Cloud")
    }

    // fallback

    @Test func fallbackMarksTheClassifierFailed() {
        let s = IntentReducer.reduce(state { $0.classifyRepairs = 1 }, .fellBack)
        #expect(s.classifyFailed)
        #expect(s.rejections.isEmpty)
    }

    @Test func fallbackIsRefusedWhenTheClassifierSucceeded() {
        let s = IntentReducer.reduce(state { $0.classifyOK = true }, .fellBack)
        #expect(!s.classifyFailed)
        #expect(s.rejections == ["fallback: the classifier already succeeded"])
    }

    // saveNote

    @Test func savedNoteSetsTheDefaultReply() {
        let s = IntentReducer.reduce(state { $0.intents = [.note] }, .noteSaved(say: nil))
        #expect(s.noteDone)
        #expect(s.say == "Saved your note.")
    }

    @Test func savedNoteKeepsTheReplyWhenATaskFollows() {
        let s = IntentReducer.reduce(state { $0.intents = [.note, .task] }, .noteSaved(say: nil))
        #expect(s.noteDone)
        #expect(s.say.isEmpty, "the task step writes the reply")
    }

    @Test func savedNoteRefusedWithoutANoteIntent() {
        let s = IntentReducer.reduce(state { $0.intents = [.discuss] }, .noteSaved(say: nil))
        #expect(!s.noteDone)
        #expect(s.rejections == ["saveNote: no note was asked for"])
    }

    @Test func savedNoteRefusedTheSecondTime() {
        let once = IntentReducer.reduce(state { $0.intents = [.note] }, .noteSaved(say: nil))
        let twice = IntentReducer.reduce(once, .noteSaved(say: nil))
        #expect(twice.rejections == ["saveNote: the note is already saved"])
    }

    @Test func failedNoteSaveReportsTheError() {
        let s = IntentReducer.reduce(state { $0.intents = [.note] }, .noteFailed("disk full"))
        #expect(s.noteDone)
        #expect(s.say == "Couldn't save your note: disk full")
    }

    // extractTask

    @Test func createdTasksAreRecordedWithTheReply() {
        let s = IntentReducer.reduce(state { $0.intents = [.task] },
                                     .tasksCreated(ids: ["t-1"], route: "On-device", say: "Reminder set.", reminderFailed: true))
        #expect(s.actionDone)
        #expect(s.taskIds == ["t-1"])
        #expect(s.route == "On-device")
        #expect(s.say == "Reminder set.")
        #expect(s.reminderFailed)
    }

    @Test func createdTasksRefusedWithoutAnyId() {
        let s = IntentReducer.reduce(state { $0.intents = [.task] },
                                     .tasksCreated(ids: [], route: "", say: nil, reminderFailed: false))
        #expect(!s.actionDone)
        #expect(s.rejections == ["extractTask: no task was created"])
    }

    @Test func createdTasksRefusedWithoutATaskIntent() {
        let s = IntentReducer.reduce(state { $0.intents = [.note] },
                                     .tasksCreated(ids: ["t-1"], route: "", say: nil, reminderFailed: false))
        #expect(s.taskIds.isEmpty)
        #expect(s.rejections == ["extractTask: the message has no task intent"])
    }

    @Test func failedTaskKeepsTheReplyWhenNoneWasGiven() {
        let s = IntentReducer.reduce(state { $0.intents = [.task]; $0.say = "kept" }, .taskFailed(route: "Cloud", say: nil))
        #expect(s.actionDone)
        #expect(s.route == "Cloud")
        #expect(s.say == "kept")
    }

    @Test func failedTaskRefusedTheSecondTime() {
        let once = IntentReducer.reduce(state { $0.intents = [.task] }, .taskFailed(route: "", say: nil))
        let twice = IntentReducer.reduce(once, .taskFailed(route: "", say: nil))
        #expect(twice.rejections == ["extractTask: the task step already ran"])
    }

    // answer

    @Test func committedAnswerKeepsResultsAndItsReply() {
        let results: [JSONValue] = [.object(["id": .string("t-1")])]
        let s = IntentReducer.reduce(state { $0.intents = [.discuss] },
                                     .answered(route: "On-device", results: results, say: "One task.", committed: true))
        #expect(s.answered)
        #expect(s.results == results)
        #expect(s.say == "One task.")
        #expect(!s.clarifyNeeded)
    }

    @Test func committedAnswerWithoutTextGetsADefaultReply() {
        let s = IntentReducer.reduce(state { $0.intents = [.discuss] },
                                     .answered(route: "", results: [], say: "", committed: true))
        #expect(s.say == "Here is what I found.")
    }

    @Test func uncommittedAnswerGoesToClarify() {
        let s = IntentReducer.reduce(state { $0.intents = [.discuss] },
                                     .answered(route: "", results: [], say: "ignored", committed: false))
        #expect(s.answered)
        #expect(s.clarifyNeeded)
        #expect(s.say.isEmpty)
    }

    @Test func unavailableAnswerSaysSo() {
        let s = IntentReducer.reduce(state { $0.intents = [.discuss] }, .answerUnavailable)
        #expect(s.answered)
        #expect(s.say == "I couldn't answer that right now.")
    }

    @Test func answerRefusedWithoutDiscuss() {
        let s = IntentReducer.reduce(state { $0.intents = [.note] }, .answerUnavailable)
        #expect(!s.answered)
        #expect(s.rejections == ["answer: the message is not a question or chat"])
    }

    // followUp

    @Test func followUpReplacesTheAnswerWhenItHasOne() {
        let results: [JSONValue] = [.object(["id": .string("t-1")])]
        let s = IntentReducer.reduce(state { $0.answered = true; $0.results = results; $0.say = "first" },
                                     .followedUp(say: "second"))
        #expect(s.followedUp)
        #expect(s.say == "second")
    }

    @Test func followUpWithoutAnswerKeepsTheReply() {
        let results: [JSONValue] = [.object(["id": .string("t-1")])]
        let s = IntentReducer.reduce(state { $0.answered = true; $0.results = results; $0.say = "first" },
                                     .followedUp(say: nil))
        #expect(s.followedUp)
        #expect(s.say == "first")
    }

    @Test func followUpRefusedWithoutResults() {
        let s = IntentReducer.reduce(state { $0.answered = true }, .followedUp(say: "x"))
        #expect(!s.followedUp)
        #expect(s.rejections == ["followUp: there are no read results to answer from"])
    }

    @Test func followUpRefusedBeforeTheAnswerStep() {
        let s = IntentReducer.reduce(state { $0.results = [.null] }, .followedUp(say: "x"))
        #expect(s.rejections == ["followUp: the answer step has not run"])
    }

    // clarify

    @Test func clarifyUsesTheFixedQuestionWhenTheModelFailed() {
        let s = IntentReducer.reduce(state { $0.clarifyNeeded = true }, .clarified(say: nil, route: ""))
        #expect(s.say == "Do you want me to save that as a note, or set a task?")
        #expect(s.route.isEmpty, "a failed clarify keeps the route as it was")
    }

    @Test func clarifyKeepsTheModelsReplyAndRoute() {
        let s = IntentReducer.reduce(state { $0.intents = [.unclear] }, .clarified(say: "Which time?", route: "On-device"))
        #expect(s.say == "Which time?")
        #expect(s.route == "On-device")
    }

    @Test func clarifyRefusedWhenNothingNeedsAQuestion() {
        let s = IntentReducer.reduce(state { $0.intents = [.note] }, .clarified(say: "x", route: ""))
        #expect(s.say.isEmpty)
        #expect(s.rejections == ["clarify: nothing needs a question"])
    }

    // The store applies every action and keeps the sequence.

    @Test func storeAppliesEveryActionInOrder() {
        var store = IntentStore(state { $0.intents = [.note, .task] })
        store.dispatch(.noteSaved(say: nil))
        store.dispatch(.tasksCreated(ids: ["t-1"], route: "On-device", say: "Done.", reminderFailed: false))
        #expect(store.state.noteDone)
        #expect(store.state.actionDone)
        #expect(store.state.say == "Done.")
        #expect(store.log.map(\.step) == [.saveNote, .extractTask])
    }
}

// MARK: - Whole graph: every route keeps its contracts

/// Runs complete turns through the graph. Each route must finish with no gate refusals.
@MainActor @Suite struct IntentGraphGateTests {
    private func assistant(_ model: FakeModel, store: PocketStore) -> Assistant {
        Assistant(store: store, model: model, clock: { t0 }, timeZone: utc)
    }

    @Test func noteRouteKeepsItsContracts() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([(#"{"intents":["note"]}"#, .onDevice)])
        let turn = try await assistant(model, store: store).handle("I have a meeting with Anna on Monday.", policy: .auto)
        #expect(turn.gateRejections.isEmpty)
        #expect(try await store.recentNotes(limit: 10).count == 1)
    }

    @Test func mixedRouteKeepsItsContracts() async throws {
        let store = try makeMemoryStore()
        let task = #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Fix the pricing page"}}],"say":"Added."}"#
        let model = FakeModel([(#"{"intents":["note","task"]}"#, .onDevice), (task, .onDevice)])
        let turn = try await assistant(model, store: store).handle("The checkout test is blocked. Fix the pricing page.", policy: .auto)
        #expect(turn.gateRejections.isEmpty)
        #expect(turn.taskIds.count == 1)
    }

    @Test func questionRouteKeepsItsContracts() async throws {
        let model = FakeModel([(#"{"intents":["discuss"]}"#, .onDevice), (#"{"calls":[],"say":"Nothing saved yet."}"#, .onDevice)])
        let turn = try await assistant(model, store: try makeMemoryStore()).handle("What did I note?", policy: .auto)
        #expect(turn.gateRejections.isEmpty)
        #expect(turn.say == "Nothing saved yet.")
    }

    @Test func unclearRouteKeepsItsContracts() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([(#"{"intents":["unclear"]}"#, .onDevice), (#"{"calls":[],"say":"Which time on Friday?"}"#, .onDevice)])
        let turn = try await assistant(model, store: store).handle("Remind me to call the landlord Friday morning.", policy: .auto)
        #expect(turn.gateRejections.isEmpty)
        #expect(try await store.openTasks().isEmpty)
    }

    /// The classifier never gives a usable reply: the turn falls back to a question, and the gates still hold.
    @Test func classifierFailureRouteKeepsItsContracts() async throws {
        let model = FakeModel([("x", .onDevice), ("y", .onDevice), ("z", .cloud)])
        let turn = try await assistant(model, store: try makeMemoryStore()).handle("Something.", policy: .auto)
        #expect(turn.gateRejections.isEmpty)
        #expect(turn.say == "Do you want me to save that as a note, or set a task?")
    }
}
