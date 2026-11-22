import Foundation
import Testing
@testable import florque_pocket

// Purpose: checks the `cer` workflow stage by stage. Each step's gate, prompt, processing, parser and reducer are
// tested on their own, then the runner (a refused gate never calls the model; stages are logged in order). Then the
// budget, the tools, and whole turns through `Assistant`.
//
// Testing approach: the model is `FakeModel` (scripted replies), reminders are `FakeReminders`, and stores are
// in memory. Assertions are on the state, the store objects and the model call count.

private let cerNow = Date(timeIntervalSince1970: 1_795_000_000)
private let utc = TimeZone(identifier: "UTC")!

private func cerState(_ text: String = "hi", history: [String] = []) -> CERState {
    CERState(text: text, history: history, policy: .auto, now: cerNow, noteId: "note-1", timeZone: utc)
}

private func unwrap<T>(_ checked: Checked<T>) -> T? {
    if case .ok(let value) = checked { return value }
    return nil
}

private func reason<T>(_ checked: Checked<T>) -> String? {
    if case .rejected(let why) = checked { return why }
    return nil
}

// MARK: - Parsers

@Suite struct CERParserTests {
    @Test func classifyAcceptsAKnownIntent() throws {
        let out = try #require(unwrap(CERParse.classify(#"{"intent":"record","reason":"a note"}"#)))
        #expect(out.intent == .record)
        #expect(out.reason == "a note")
    }

    @Test func classifyRejectsAnUnknownIntent() {
        #expect(reason(CERParse.classify(#"{"intent":"shopping","reason":"x"}"#)) != nil)
    }

    @Test func extractTurnsAMissingEventTimeIntoMissing() throws {
        let text = #"{"calls":[{"tool":"record_event","args":{"title":"Dentist"}}],"missing":[]}"#
        let extraction = try #require(unwrap(CERParse.extract(text, intent: .record)))
        #expect(extraction.calls.isEmpty)
        #expect(extraction.missing == ["time"])
    }

    @Test func classifyRejectsEventAndListsTheValidIntents() {
        guard case .rejected(let why) = CERParse.classify(#"{"intent":"event","reason":"schedule"}"#) else {
            Issue.record("event is not an intent"); return
        }
        #expect(why.contains("record, retrieve, chat or unclear"))
    }

    @Test func extractRejectsAnInventedTool() {
        let text = #"{"calls":[{"tool":"say","args":{"content":"Hello"}}],"missing":[]}"#
        let why = reason(CERParse.extract(text, intent: .chat))
        #expect(why?.contains("say") == true)
    }

    @Test func extractRejectsAToolOfAnotherIntent() {
        let text = #"{"calls":[{"tool":"retrieve_notes","args":{}}],"missing":[]}"#
        #expect(reason(CERParse.extract(text, intent: .record)) != nil)
    }

    @Test func sayAcceptsJSONAndProse() {
        #expect(unwrap(CERParse.say(#"{"say":"Saved."}"#)) == "Saved.")
        #expect(unwrap(CERParse.say("Hello there")) == "Hello there")
    }
}

// MARK: - Classify step

@Suite @MainActor struct CERClassifyStepTests {
    @Test func gateAcceptsAFreshMessageAndRefusesAnEmptyOne() {
        #expect(unwrap(ClassifyStep(repair: false).gate(cerState())) != nil)
        #expect(reason(ClassifyStep(repair: false).gate(cerState("   "))) != nil)
    }

    @Test func repairGateRunsOnlyAfterOneFailure() {
        var s = cerState()
        #expect(reason(ClassifyStep(repair: true).gate(s)) != nil)
        s = ClassifyStep(repair: false).reduce(s, ClassifyStep.Input(turn: CERTurnValues(s, repair: false)),
                                               .rejected("bad"))
        #expect(unwrap(ClassifyStep(repair: true).gate(s)) != nil)
    }

    @Test func classifyPromptSaysEventIsNotAnIntentAndGivesAnExamplePerIntent() {
        let system = ClassifyStep(repair: false).prompt(
            ClassifyStep.Input(turn: CERTurnValues(cerState(), repair: false))).system
        #expect(system.contains(#""event" and "note" are things, never intents."#))
        for example in [#""hi" -> chat"#, #""Dentist Friday 9am" -> record"#, #""What events do I have tomorrow?" -> retrieve"#, #""tomorrow" -> unclear"#] {
            #expect(system.contains(example))
        }
    }

    @Test func classifyRepairPromptNamesTheMistake() {
        let system = ClassifyStep(repair: true).prompt(
            ClassifyStep.Input(turn: CERTurnValues(cerState(), repair: true))).system
        #expect(system.contains(#""event" and "note" are not intents"#))
    }

    @Test func promptHoldsTheMessageAndTheReplyShape() throws {
        let input = try #require(unwrap(ClassifyStep(repair: false).gate(cerState("buy milk"))))
        let prompt = ClassifyStep(repair: false).prompt(input)
        #expect(prompt.user.contains("MESSAGE: buy milk"))
        #expect(prompt.system.contains(#""intent""#))
    }

    @Test func processReturnsTheScriptedReply() async throws {
        let model = FakeModel([(#"{"intent":"chat","reason":"hello"}"#, .onDevice)])
        let input = try #require(unwrap(ClassifyStep(repair: false).gate(cerState("hi"))))
        let env = CEREnv(model: model, store: try makeMemoryStore(), reminders: nil)
        let step = ClassifyStep(repair: false)
        let raw = await step.process(step.prompt(input), input, env)
        #expect(unwrap(raw) == #"{"intent":"chat","reason":"hello"}"#)
    }

    @Test func processTurnsAThrownErrorIntoARejection() async throws {
        let model = FakeModel([])
        let input = try #require(unwrap(ClassifyStep(repair: false).gate(cerState("hi"))))
        let env = CEREnv(model: model, store: try makeMemoryStore(), reminders: nil)
        let step = ClassifyStep(repair: false)
        #expect(reason(await step.process(step.prompt(input), input, env)) != nil)
    }

    @Test func reduceSetsTheIntentAndRefusesASecondOne() throws {
        let s = cerState()
        let input = ClassifyStep.Input(turn: CERTurnValues(s, repair: false))
        let step = ClassifyStep(repair: false)
        let once = step.reduce(s, input, .ok(CERClassifyOutput(intent: .record, reason: "a")))
        #expect(once.intent == .record)
        let twice = step.reduce(once, input, .ok(CERClassifyOutput(intent: .chat, reason: "b")))
        #expect(twice.intent == .record)
        #expect(twice.rejections.count == 1)
    }

    @Test func reduceCountsAFailedAttemptAndKeepsTheProblem() {
        let s = cerState()
        let input = ClassifyStep.Input(turn: CERTurnValues(s, repair: false))
        let after = ClassifyStep(repair: false).reduce(s, input, .rejected("no JSON"))
        #expect(after.classifyAttempts == 1)
        #expect(after.problem == "no JSON")
    }
}

// MARK: - Extract step

@Suite @MainActor struct CERExtractStepTests {
    private func classified(_ intent: CERIntent, _ text: String = "x") -> CERState {
        ClassifyStep(repair: false).reduce(cerState(text), ClassifyStep.Input(turn: CERTurnValues(cerState(text), repair: false)),
                                           .ok(CERClassifyOutput(intent: intent, reason: "r")))
    }

    @Test func gateRefusesWithoutAnIntentAndForUnclear() {
        #expect(reason(ExtractStep(repair: false).gate(cerState())) != nil)
        #expect(reason(ExtractStep(repair: false).gate(classified(.unclear))) != nil)
        #expect(unwrap(ExtractStep(repair: false).gate(classified(.record))) != nil)
    }

    @Test func promptListsOnlyTheToolsOfTheIntent() throws {
        let input = try #require(unwrap(ExtractStep(repair: false).gate(classified(.record))))
        let system = ExtractStep(repair: false).prompt(input).system
        #expect(system.contains("record_note"))
        #expect(!system.contains("retrieve_notes"))
    }

    @Test func processReturnsTheScriptedCalls() async throws {
        let model = FakeModel([(#"{"calls":[{"tool":"record_note","args":{"body":"milk"}}],"missing":[]}"#, .onDevice)])
        let input = try #require(unwrap(ExtractStep(repair: false).gate(classified(.record))))
        let env = CEREnv(model: model, store: try makeMemoryStore(), reminders: nil)
        let step = ExtractStep(repair: false)
        let raw = await step.process(step.prompt(input), input, env)
        #expect(unwrap(raw)?.contains("record_note") == true)
    }

    @Test func parseTurnsAMissingTimeIntoMissing() throws {
        let input = try #require(unwrap(ExtractStep(repair: false).gate(classified(.record))))
        let parsed = ExtractStep(repair: false).parse(#"{"calls":[{"tool":"record_event","args":{"title":"Dentist"}}]}"#, input)
        #expect(unwrap(parsed)?.missing == ["time"])
    }

    @Test func reduceCountsAFailedExtraction() {
        let s = classified(.record)
        let input = ExtractStep.Input(turn: CERTurnValues(s, repair: false), intent: .record)
        let after = ExtractStep(repair: false).reduce(s, input, .rejected("bad args"))
        #expect(after.extractAttempts == 1)
        #expect(after.problem == "bad args")
    }
}

// MARK: - Execute step

@Suite @MainActor struct CERExecuteStepTests {
    @Test func gateRefusesWhileSomethingIsMissing() {
        var s = cerState()
        s = ClassifyStep(repair: false).reduce(s, ClassifyStep.Input(turn: CERTurnValues(s, repair: false)),
                                               .ok(CERClassifyOutput(intent: .record, reason: "e")))
        s = ExtractStep(repair: false).reduce(s, ExtractStep.Input(turn: CERTurnValues(s, repair: false), intent: .record),
                                              .ok(CERExtraction(calls: [], missing: ["time"])))
        #expect(reason(ExecuteStep().gate(s)) != nil)
    }

    @Test func processRunsTheCallsOnTheStore() async throws {
        let store = try makeMemoryStore()
        let env = CEREnv(model: FakeModel([]), store: store, reminders: nil)
        let s = cerState("milk")
        let call = CERCall(tool: "record_note", args: ["body": .string("milk")])
        let input = ExecuteStep.Input(extraction: CERExtraction(calls: [call], missing: []),
                                      turn: CERTurnValues(s, repair: false))
        let step = ExecuteStep()
        let results = await step.process(NoPrompt(), input, env)
        #expect(unwrap(results)?.count == 1)
        #expect(try await store.recentNotes(limit: 5).first?.body == "milk")
    }

    @Test func aToolErrorBecomesARejection() async throws {
        let env = CEREnv(model: FakeModel([]), store: try makeMemoryStore(), reminders: nil)
        let s = cerState()
        let call = CERCall(tool: "record_event", args: ["title": .string("Dentist"), "when": .string("soon")])
        let input = ExecuteStep.Input(extraction: CERExtraction(calls: [call], missing: []),
                                      turn: CERTurnValues(s, repair: false))
        #expect(reason(await ExecuteStep().process(NoPrompt(), input, env)) != nil)
    }

    @Test func reduceKeepsAToolErrorForTheClarifyStep() {
        let s = cerState()
        let input = ExecuteStep.Input(extraction: CERExtraction(calls: [], missing: []),
                                      turn: CERTurnValues(s, repair: false))
        let after = ExecuteStep().reduce(s, input, .rejected("record_event: bad time"))
        #expect(after.executed)
        #expect(after.toolError == "record_event: bad time")
    }
}

// MARK: - Respond step

@Suite @MainActor struct CERRespondStepTests {
    private func executed(_ results: [CERToolResult] = []) -> CERState {
        var s = cerState()
        s.executed = true
        s.results = results
        return s
    }

    @Test func gateRefusesBeforeTheToolsRan() {
        #expect(reason(RespondStep(repair: false).gate(cerState())) != nil)
        #expect(unwrap(RespondStep(repair: false).gate(executed())) != nil)
    }

    @Test func promptCarriesTheResults() throws {
        let result = CERToolResult(tool: "record_note", items: [], summary: "Saved note: milk")
        let input = try #require(unwrap(RespondStep(repair: false).gate(executed([result]))))
        #expect(RespondStep(repair: false).prompt(input).user.contains("Saved note: milk"))
    }

    @Test func parseAcceptsProse() {
        let input = RespondStep.Input(turn: CERTurnValues(executed(), repair: false), results: [], resultsText: "")
        #expect(unwrap(RespondStep(repair: false).parse("Saved it.", input)) == "Saved it.")
    }

    @Test func reduceSetsTheReply() {
        let s = executed()
        let input = RespondStep.Input(turn: CERTurnValues(s, repair: false), results: [], resultsText: "")
        #expect(RespondStep(repair: false).reduce(s, input, .ok("Hi!")).say == "Hi!")
    }

    @Test func repairThatStillFailsAnswersFromTheResultsInCode() {
        let s = executed([CERToolResult(tool: "record_note", items: [], summary: "Saved note: milk")])
        let input = RespondStep.Input(turn: CERTurnValues(s, repair: true), results: s.results, resultsText: "")
        let after = RespondStep(repair: true).reduce(s, input, .rejected("not JSON"))
        #expect(after.say == "Saved note: milk")
    }
}

// MARK: - Clarify step

@Suite @MainActor struct CERClarifyStepTests {
    @Test func gateRefusesWhenNothingNeedsAQuestion() {
        var chatty = cerState()
        chatty.intent = .chat
        #expect(reason(ClarifyStep().gate(chatty)) != nil)
        #expect(unwrap(ClarifyStep().gate(cerState())) != nil, "no intent yet needs a question")
    }

    @Test func fallbackAsksForTheMissingTime() {
        var s = cerState()
        s.extraction = CERExtraction(calls: [], missing: ["time"])
        let input = ClarifyStep.Input(turn: CERTurnValues(s, repair: false), missing: ["time"], toolError: nil, intent: .record)
        let after = ClarifyStep().reduce(s, input, .rejected("the model call failed"))
        #expect(after.question == "When should it happen? Please give a date and time.")
        #expect(after.say == after.question)
    }
}

// MARK: - Runner

@Suite @MainActor struct CERRunnerTests {
    @Test func aRefusedGateNeverCallsTheModel() async throws {
        let model = FakeModel([])
        let env = CEREnv(model: model, store: try makeMemoryStore(), reminders: nil)
        let after = await CERStepRunner.run(ClassifyStep(repair: true), cerState(), env: env)
        #expect(model.calls.isEmpty)
        #expect(!after.rejections.isEmpty)
        #expect(after.log.first?.stage == .refused)
    }

    @Test func aRunLogsItsStagesInOrder() async throws {
        let model = FakeModel([(#"{"intent":"chat","reason":"hi"}"#, .onDevice)])
        let env = CEREnv(model: model, store: try makeMemoryStore(), reminders: nil)
        let after = await CERStepRunner.run(ClassifyStep(repair: false), cerState("hello"), env: env)
        #expect(after.log.map(\.stage) == [.gate, .prompt, .parse, .reduce])
        #expect(after.intent == .chat)
    }
}

// MARK: - Budget

@Suite struct CERBudgetTests {
    @Test func worstCaseInputStaysUnderTheLimit() {
        let text = String(repeating: "я", count: TokenBudget.maxMessageChars)
        let history = (0..<5).map { _ in String(repeating: "h", count: 1000) }
        let results = String(repeating: "r", count: TokenBudget.maxResultChars)
        let tokens = TokenBudget.inputTokens(text: text, history: TokenBudget.history(history), results: results)
        #expect(tokens < TokenBudget.inputLimit)
    }

    @Test func historyKeepsTheLastFiveLinesAndClipsThem() {
        let lines = (1...8).map { "line \($0) " + String(repeating: "x", count: 500) }
        let kept = TokenBudget.history(lines)
        #expect(kept.count == 5)
        #expect(kept.first?.hasPrefix("line 4") == true)
        #expect(kept.allSatisfy { $0.count <= TokenBudget.maxHistoryLineChars })
    }
}

// MARK: - Tools

@Suite struct CERToolTests {
    private func context(_ store: PocketStore, reminders: (any RemindersAdapter)? = nil) -> CERToolContext {
        CERToolContext(store: store, timeZone: utc, now: cerNow, reminders: reminders)
    }

    @Test func recordNoteSavesTheBody() async throws {
        let store = try makeMemoryStore()
        let result = try await RecordNoteTool().run(["body": .string("buy milk")], context(store))
        #expect(result.items.count == 1)
        #expect(try await store.recentNotes(limit: 5).first?.body == "buy milk")
    }

    @Test func recordEventNeedsAParseableWhen() {
        #expect(RecordEventTool().problem(["title": .string("Dentist")]) != nil)
        #expect(RecordEventTool().problem(["title": .string("Dentist"), "when": .string("soon")]) != nil)
        #expect(RecordEventTool().problem(["title": .string("Dentist"), "when": .string("2026-11-27T09:00:00")]) == nil)
    }

    @Test @MainActor func recordEventSavesATaskWithItsTimeAndReminder() async throws {
        let store = try makeMemoryStore()
        let reminders = FakeReminders()
        let args: [String: JSONValue] = ["title": .string("Dentist"), "when": .string("2026-11-27T09:00:00")]
        let result = try await RecordEventTool().run(args, context(store, reminders: reminders))
        #expect(result.items.first?.when != nil)
        let events = try await store.events(text: nil, from: nil, to: nil, limit: 5)
        #expect(events.map(\.title) == ["Dentist"])
        #expect(events.first?.eventId != nil)
        #expect(reminders.created.count == 1)
    }

    @Test func retrieveEventsFiltersByTitle() async throws {
        let store = try makeMemoryStore()
        let args: [String: JSONValue] = ["title": .string("Dentist"), "when": .string("2026-11-27T09:00:00")]
        _ = try await RecordEventTool().run(args, context(store))
        let found = try await RetrieveEventsTool().run(["query": .string("dent")], context(store))
        #expect(found.items.count == 1)
        let none = try await RetrieveEventsTool().run(["query": .string("gym")], context(store))
        #expect(none.items.isEmpty)
    }

    @Test func toolboxListsOnlyTheToolsOfAnIntent() {
        #expect(CERToolbox.tools(for: .record).map(\.name) == ["record_note", "record_event"])
        #expect(CERToolbox.tools(for: .chat).isEmpty)
    }
}

// MARK: - Whole turns

@Suite @MainActor struct CERTurnTests {
    private func make(_ model: FakeModel, store: PocketStore) -> Assistant {
        Assistant(store: store, model: model, clock: { cerNow }, timeZone: utc, workflow: .cer)
    }

    @Test func noteIsSavedAndAnswered() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([
            (#"{"intent":"record","reason":"a note"}"#, .onDevice),
            (#"{"calls":[{"tool":"record_note","args":{"body":"buy milk"}}],"missing":[]}"#, .onDevice),
            (#"{"say":"Saved your note."}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("buy milk", policy: .forceOnDevice)
        #expect(turn.say == "Saved your note.")
        #expect(model.calls.count == 3)
        #expect(try await store.recentNotes(limit: 5).count == 1)
        #expect(turn.gateRejections.isEmpty)
    }

    @Test func eventWithoutATimeAsksAndSavesNothing() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([
            (#"{"intent":"record","reason":"an event"}"#, .onDevice),
            (#"{"calls":[{"tool":"record_event","args":{"title":"Dentist"}}],"missing":[]}"#, .onDevice),
            (#"{"say":"When should it happen?"}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("dentist", policy: .forceOnDevice)
        #expect(turn.say == "When should it happen?")
        #expect(try await store.events(text: nil, from: nil, to: nil, limit: 5).isEmpty)
        #expect(model.calls.count == 3)
    }

    @Test func eventAnswerIsRepairedToRecordOnTheCloud() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([
            (#"{"intent":"event","reason":"schedule"}"#, .onDevice),
            (#"{"intent":"record","reason":"dentist"}"#, .cloud),
            (#"{"calls":[{"tool":"record_note","args":{"body":"dentist"}}],"missing":[]}"#, .onDevice),
            (#"{"say":"Saved."}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("dentist friday", policy: .auto)
        #expect(turn.say == "Saved.")
        #expect(model.calls.count == 4, "one classify repair, then extract and respond")
        #expect(model.calls[1].policy == .forceCloud)
    }

    @Test func unclearMessageAsksWithoutTools() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([
            (#"{"intent":"unclear","reason":"no idea"}"#, .onDevice),
            (#"{"say":"What would you like to do?"}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("asdf", policy: .forceOnDevice)
        #expect(turn.say == "What would you like to do?")
        #expect(model.calls.count == 2)
    }

    @Test func twoBadClassificationsEndInTheFixedQuestion() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([
            ("not json", .onDevice),
            ("still not json", .onDevice),
        ])
        let turn = try await make(model, store: store).handle("hello", policy: .forceOnDevice)
        #expect(turn.say.hasPrefix("What would you like to do"))
        #expect(model.calls.count == 3, "classify, one repair, then a clarify call that fails and falls back")
    }
}
