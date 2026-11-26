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
        let out = try #require(unwrap(CERParse.classify(#"{"intent":"record_note","reason":"a note"}"#)))
        #expect(out.intent == .recordNote)
        #expect(out.reason == "a note")
    }

    @Test func classifyRejectsAnUnknownIntent() {
        #expect(reason(CERParse.classify(#"{"intent":"shopping","reason":"x"}"#)) != nil)
    }

    @Test func extractReportsMissingNodesInsteadOfACall() throws {
        let extraction = try #require(unwrap(CERParse.extract(#"{"args":{}}"#, intent: .recordEvent)))
        #expect(extraction.calls.isEmpty)
        #expect(extraction.missing == ["nodes"])
    }

    @Test func extractReadsTheFlattenedFormTheModelSometimesWrites() throws {
        let text = #"{"tool":"record","nodes":[{"ref":"i","type":"event","title":"Interview","dueAt":"2026-11-23T10:00:00"}]}"#
        let extraction = try #require(unwrap(CERParse.extract(text, intent: .recordEvent)))
        #expect(extraction.missing.isEmpty)
        #expect(extraction.calls == [CERCall(tool: "record", args: [
            "nodes": .array([.object(["ref": .string("i"), "type": .string("event"),
                                      "title": .string("Interview"), "dueAt": .string("2026-11-23T10:00:00")])]),
        ])])
    }

    @Test func extractRejectsNodesThatAreNotAList() {
        let text = #"{"args":{"nodes":"Dentist"}}"#
        #expect(reason(CERParse.extract(text, intent: .recordEvent)) != nil)
    }

    @Test func classifyRejectsEventAndListsTheValidIntents() {
        guard case .rejected(let why) = CERParse.classify(#"{"intent":"event","reason":"schedule"}"#) else {
            Issue.record("event is not an intent"); return
        }
        #expect(why.contains("record_note, record_event, retrieve_notes, retrieve_events, chat, unclear"))
    }

    @Test func extractRejectsAChatMessageBecauseItHasNoTool() {
        #expect(reason(CERParse.extract(#"{"args":{"content":"Hello"}}"#, intent: .chat)) != nil)
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
        #expect(system.contains(#""event" and "note" are not values."#))
        for example in [#""hi" -> chat"#, #""Wifi code is 4411" -> record_note"#, #""What events do I have tomorrow?" -> retrieve_events"#, #""tomorrow" -> unclear"#] {
            #expect(system.contains(example))
        }
    }

    @Test func classifyRepairPromptNamesTheMistake() {
        let system = ClassifyStep(repair: true).prompt(
            ClassifyStep.Input(turn: CERTurnValues(cerState(), repair: true))).system
        #expect(system.contains(#""event" and "note" alone are not values"#))
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
        let once = step.reduce(s, input, .ok(CERClassifyOutput(intent: .recordNote, reason: "a")))
        #expect(once.intent == .recordNote)
        let twice = step.reduce(once, input, .ok(CERClassifyOutput(intent: .chat, reason: "b")))
        #expect(twice.intent == .recordNote)
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
        #expect(unwrap(ExtractStep(repair: false).gate(classified(.recordNote))) != nil)
    }

    @Test func promptShowsOnlyTheChosenTool() throws {
        let input = try #require(unwrap(ExtractStep(repair: false).gate(classified(.recordEvent))))
        let system = ExtractStep(repair: false).prompt(input).system
        #expect(system.contains("Tool: record(nodes"))
        #expect(!system.contains("retrieve("))
    }

    @Test func processReturnsTheScriptedCalls() async throws {
        let model = FakeModel([(#"{"args":{"nodes":[{"ref":"m","type":"note","title":"Milk"}]}}"#, .onDevice)])
        let input = try #require(unwrap(ExtractStep(repair: false).gate(classified(.recordNote))))
        let env = CEREnv(model: model, store: try makeMemoryStore(), reminders: nil)
        let step = ExtractStep(repair: false)
        let raw = await step.process(step.prompt(input), input, env)
        #expect(unwrap(raw)?.contains("Milk") == true)
    }

    @Test func parseTurnsMissingNodesIntoMissing() throws {
        let input = try #require(unwrap(ExtractStep(repair: false).gate(classified(.recordEvent))))
        let parsed = ExtractStep(repair: false).parse(#"{"args":{}}"#, input)
        #expect(unwrap(parsed)?.missing == ["nodes"])
    }

    @Test func reduceCountsAFailedExtraction() {
        let s = classified(.recordNote)
        let input = ExtractStep.Input(turn: CERTurnValues(s, repair: false), intent: .recordNote, tool: RecordTool())
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
                                               .ok(CERClassifyOutput(intent: .recordEvent, reason: "e")))
        s = ExtractStep(repair: false).reduce(s, ExtractStep.Input(turn: CERTurnValues(s, repair: false), intent: .recordEvent,
                                                                   tool: RecordTool()),
                                              .ok(CERExtraction(calls: [], missing: ["when"])))
        #expect(reason(ExecuteStep().gate(s)) != nil)
    }

    @Test func processRunsTheCallsOnTheStore() async throws {
        let store = try await seededStore()
        let env = CEREnv(model: FakeModel([]), store: store, reminders: nil)
        let s = cerState("milk")
        let call = CERCall(tool: "record", args: ["nodes": .array([.object(["ref": .string("m"), "type": .string("note"), "title": .string("milk")])])])
        let input = ExecuteStep.Input(extraction: CERExtraction(calls: [call], missing: []),
                                      turn: CERTurnValues(s, repair: false))
        let step = ExecuteStep()
        let results = await step.process(NoPrompt(), input, env)
        #expect(unwrap(results)?.count == 1)
        #expect(try await store.nodes().first?.title == "milk")
    }

    @Test func aToolErrorBecomesARejection() async throws {
        let env = CEREnv(model: FakeModel([]), store: try makeMemoryStore(), reminders: nil)
        let s = cerState()
        let call = CERCall(tool: "no_such_tool", args: [:])
        let input = ExecuteStep.Input(extraction: CERExtraction(calls: [call], missing: []),
                                      turn: CERTurnValues(s, repair: false))
        #expect(reason(await ExecuteStep().process(NoPrompt(), input, env)) != nil)
    }

    @Test func reduceKeepsAToolErrorForTheClarifyStep() {
        let s = cerState()
        let input = ExecuteStep.Input(extraction: CERExtraction(calls: [], missing: []),
                                      turn: CERTurnValues(s, repair: false))
        let after = ExecuteStep().reduce(s, input, .rejected("record: bad time"))
        #expect(after.executed)
        #expect(after.toolError == "record: bad time")
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
        s.extraction = CERExtraction(calls: [], missing: ["when"])
        let input = ClarifyStep.Input(turn: CERTurnValues(s, repair: false), missing: ["when"], toolError: nil, intent: .recordEvent)
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

/// An in-memory store with the default node and link types, as the app starts with.
private func seededStore() async throws -> PocketStore {
    let store = try makeMemoryStore()
    try await store.seedGraphDefaults()
    return store
}

@Suite @MainActor struct CERToolTests {
    private func context(_ store: PocketStore, reminders: (any RemindersAdapter)? = nil) -> CERToolContext {
        CERToolContext(store: store, timeZone: utc, now: cerNow, reminders: reminders)
    }

    private let anna: JSONValue = .object(["ref": .string("anna"), "type": .string("person"), "title": .string("Anna")])
    private let interview: JSONValue = .object([
        "ref": .string("interview"), "type": .string("event"), "title": .string("Interview"),
        "dueAt": .string("2026-11-27T10:00:00"),
    ])
    private let participates: JSONValue = .object(["type": .string("participates"), "from": .string("anna"), "to": .string("interview")])

    @Test func recordSavesNodesAndLinksAndSchedulesTheReminder() async throws {
        let store = try await seededStore()
        let reminders = FakeReminders()
        let args: [String: JSONValue] = ["nodes": .array([anna, interview]), "edges": .array([participates])]
        let result = try await RecordTool().run(args, context(store, reminders: reminders))
        #expect(try await store.nodes().count == 2)
        #expect(try await store.edges().count == 1)
        #expect(reminders.created.count == 1, "only the event type schedules a reminder")
        #expect(result.changeset?.reminderIds == ["ek-1"])
        #expect(result.items.map(\.title).sorted() == ["Anna", "Interview"])
    }

    @Test func recordWithoutAnyNodesSavesNothing() async throws {
        let store = try await seededStore()
        let result = try await RecordTool().run(["nodes": .array([])], context(store))
        #expect(result.summary == "Nothing to remember.")
        #expect(result.changeset == nil)
        #expect(try await store.nodes().isEmpty)
    }

    @Test func recordReportsRejectedItemsInItsSummary() async throws {
        let store = try await seededStore()
        let spaceship: JSONValue = .object(["ref": .string("x"), "type": .string("spaceship"), "title": .string("Apollo")])
        let result = try await RecordTool().run(["nodes": .array([spaceship, anna])], context(store))
        #expect(result.summary.contains("unknown type spaceship"))
        #expect(try await store.nodes().map(\.title) == ["Anna"])
    }

    @Test func aTimedEventWithoutATimeIsSavedAndTheSummaryAsksForIt() async throws {
        let store = try await seededStore()
        let reminders = FakeReminders()
        let dentist: JSONValue = .object(["ref": .string("d"), "type": .string("event"), "title": .string("Dentist")])
        let result = try await RecordTool().run(["nodes": .array([dentist])], context(store, reminders: reminders))
        #expect(result.summary.contains("No time given for Dentist"))
        #expect(reminders.created.isEmpty)
        #expect(try await store.nodes().first?.dueAt == nil)
    }

    @Test func recordRejectsNodesThatAreNotAList() {
        #expect(RecordTool().problem(["nodes": .string("x")]) != nil)
        #expect(RecordTool().problem(["nodes": .array([])]) == nil)
        #expect(RecordTool().problem(["nodes": .array([]), "edges": .string("x")]) != nil)
    }

    @Test func retrieveFindsByWordsAndAddsTheLinkedNode() async throws {
        let store = try await seededStore()
        _ = try await RecordTool().run(["nodes": .array([anna, interview]), "edges": .array([participates])],
                                       context(store))
        let found = try await RetrieveTool().run(["query": .string("anna")], context(store))
        #expect(Set(found.items.map(\.title)) == ["Anna", "Interview"], "the event is the one-hop neighbour")
        let none = try await RetrieveTool().run(["query": .string("gym")], context(store))
        #expect(none.items.isEmpty)
        #expect(none.summary == "No matching items found.")
    }

    @Test func retrieveRejectsANonNumericLimit() {
        #expect(RetrieveTool().problem(["limit": .string("many")]) != nil)
        #expect(RetrieveTool().problem(["limit": .number(3)]) == nil)
    }

    @Test func aClassifierValueNamesItsTool() {
        #expect(CERToolbox.tool(for: .recordEvent)?.name == "record")
        #expect(CERToolbox.tool(for: .recordNote)?.name == "record")
        #expect(CERToolbox.tool(for: .retrieveNotes)?.name == "retrieve")
        #expect(CERToolbox.tool(for: .chat) == nil)
        #expect(CERToolbox.tool(for: .unclear) == nil)
    }
}

// MARK: - Whole turns

@Suite @MainActor struct CERTurnTests {
    private func make(_ model: FakeModel, store: PocketStore) -> Assistant {
        Assistant(store: store, model: model, clock: { cerNow }, timeZone: utc, workflow: .cer)
    }

    @Test func noteIsSavedAndAnswered() async throws {
        let store = try await seededStore()
        let model = FakeModel([
            (#"{"intent":"record_note","reason":"a note"}"#, .onDevice),
            (#"{"args":{"nodes":[{"ref":"m","type":"note","title":"Buy milk"}]}}"#, .onDevice),
            (#"{"say":"Saved your note."}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("buy milk", policy: .forceOnDevice)
        #expect(turn.say == "Saved your note.")
        #expect(model.calls.count == 3)
        #expect(try await store.nodes().map(\.title) == ["Buy milk"])
        #expect(turn.changeset != nil, "the turn can be undone")
        #expect(turn.gateRejections.isEmpty)
    }

    @Test func eventWithoutATimeIsSavedAndTheReplyAsksForIt() async throws {
        let store = try await seededStore()
        let model = FakeModel([
            (#"{"intent":"record_event","reason":"an event"}"#, .onDevice),
            (#"{"args":{"nodes":[{"ref":"d","type":"event","title":"Dentist"}]}}"#, .onDevice),
            (#"{"say":"When should it happen?"}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("dentist", policy: .forceOnDevice)
        #expect(turn.say == "When should it happen?")
        let saved = try await store.nodes()
        #expect(saved.map(\.typeKey) == ["event"])
        #expect(saved.first?.dueAt == nil)
        #expect(model.calls.count == 3)
    }

    @Test func eventAnswerIsRepairedToARecordOnTheCloud() async throws {
        let store = try await seededStore()
        let model = FakeModel([
            (#"{"intent":"event","reason":"schedule"}"#, .onDevice),
            (#"{"intent":"record_note","reason":"dentist"}"#, .cloud),
            (#"{"args":{"nodes":[{"ref":"d","type":"note","title":"Dentist"}]}}"#, .onDevice),
            (#"{"say":"Saved."}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("dentist friday", policy: .auto)
        #expect(turn.say == "Saved.")
        #expect(model.calls.count == 4, "one classify repair, then extract and respond")
        #expect(model.calls[1].policy == .forceCloud)
    }

    @Test func greetingAsksNothingAndUsesTwoCalls() async throws {
        let store = try makeMemoryStore()
        let model = FakeModel([
            (#"{"intent":"chat","reason":"greeting"}"#, .onDevice),
            (#"{"say":"Hi! How can I help?"}"#, .onDevice),
        ])
        let turn = try await make(model, store: store).handle("I say hi", policy: .forceOnDevice)
        #expect(turn.say == "Hi! How can I help?")
        #expect(model.calls.count == 2, "classify and respond only")
        #expect(try await store.recentNotes(limit: 5).isEmpty)
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
