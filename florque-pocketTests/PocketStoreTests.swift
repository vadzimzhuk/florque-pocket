import Foundation
import Testing
@testable import florque_pocket

// Purpose: checks the SwiftData layer (`PocketStore`) and the tool executor that writes through it.
//
// Testing approach:
// - PocketStoreTests: each operation on an in-memory container, plus a file-backed store that is reopened, since
//   persistence is the one thing an in-memory container cannot show.
// - ToolExecutorTests: one model reply at a time, with every rejection reason, the step allow-lists, and the rule
//   that a batch with any rejected call writes nothing.

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

@Suite struct PocketStoreTests {
    @Test func savesAndReadsNoteFields() async throws {
        let store = try makeMemoryStore()
        try await store.saveNote(id: "n1", title: "First", body: "First line\nSecond line", now: t0)
        let note = try #require(try await store.note(id: "n1"))
        #expect(note.title == "First")
        #expect(note.body == "First line\nSecond line")
        #expect(note.status == .active)
        #expect(note.createdAt == t0)
    }

    @Test func addsTaskWithDueAndLinkToNote() async throws {
        let store = try makeMemoryStore()
        try await store.saveNote(id: "n1", title: "Landlord", body: "Call the landlord Friday", now: t0)
        let due = try #require(DateParsing.parse("2026-11-27T09:00:00", in: utc))
        try await store.addTasks([NewTask(id: "t1", title: "Call the landlord", due: due, about: "n1")], now: t0)

        let task = try #require(try await store.task(id: "t1"))
        #expect(task.title == "Call the landlord")
        #expect(task.status == .active)
        #expect(task.due == due)
        #expect(task.about == "n1")
        #expect(task.eventId == nil)
    }

    /// A batch with one bad link must leave nothing: the first task is rolled back with the failed save.
    @Test func failedBatchLeavesNothing() async throws {
        let store = try makeMemoryStore()
        await #expect(throws: PocketStoreError.unknownNote("missing")) {
            try await store.addTasks([
                NewTask(id: "ok", title: "should roll back", due: nil, about: nil),
                NewTask(id: "bad", title: "points at nothing", due: nil, about: "missing"),
            ], now: t0)
        }
        #expect(try await store.task(id: "ok") == nil)
        #expect(try await store.openTasks().isEmpty)
    }

    @Test func setStatusAndEventIdUpdateTheTask() async throws {
        let store = try makeMemoryStore()
        try await store.addTasks([NewTask(id: "t1", title: "Buy milk", due: nil, about: nil)], now: t0)
        try await store.setEventId("ek-9", taskId: "t1")
        try await store.setStatus(.dropped, taskId: "t1", now: t0.addingTimeInterval(60))

        let task = try #require(try await store.task(id: "t1"))
        #expect(task.eventId == "ek-9")
        #expect(task.status == .dropped)
        #expect(task.updatedAt == t0.addingTimeInterval(60))
    }

    @Test func updatingAnUnknownTaskThrows() async throws {
        let store = try makeMemoryStore()
        await #expect(throws: PocketStoreError.unknownTask("nope")) {
            try await store.setStatus(.dropped, taskId: "nope", now: t0)
        }
    }

    @Test func openTasksOrderByDueWithUndatedLast() async throws {
        let store = try makeMemoryStore()
        let later = try #require(DateParsing.parse("2026-12-01T10:00:00", in: utc))
        let sooner = try #require(DateParsing.parse("2026-11-27T09:00:00", in: utc))
        try await store.addTasks([
            NewTask(id: "undated", title: "Undated", due: nil, about: nil),
            NewTask(id: "later", title: "Later", due: later, about: nil),
            NewTask(id: "sooner", title: "Sooner", due: sooner, about: nil),
        ], now: t0)
        try await store.setStatus(.dropped, taskId: "undated", now: t0)

        #expect(try await store.openTasks().map(\.id) == ["sooner", "later"], "dropped tasks are not open")
    }

    @Test func dueTasksStopAtTheCutOff() async throws {
        let store = try makeMemoryStore()
        let due = try #require(DateParsing.parse("2026-11-27T09:00:00", in: utc))
        let after = try #require(DateParsing.parse("2026-11-30T09:00:00", in: utc))
        try await store.addTasks([
            NewTask(id: "in", title: "In time", due: due, about: nil),
            NewTask(id: "out", title: "Too late", due: after, about: nil),
            NewTask(id: "undated", title: "No time", due: nil, about: nil),
        ], now: t0)
        let cutOff = try #require(DateParsing.parse("2026-11-28T00:00:00", in: utc))
        #expect(try await store.dueTasks(before: cutOff).map(\.id) == ["in"])
    }

    @Test func searchMatchesTitlesAndBodiesIgnoringCase() async throws {
        let store = try makeMemoryStore()
        try await store.saveNote(id: "n1", title: "Pricing", body: "The checkout test is blocked", now: t0)
        try await store.addTasks([NewTask(id: "t1", title: "Fix the CHECKOUT page", due: nil, about: nil)], now: t0)

        let all = try await store.search(text: "checkout", kind: nil, limit: 10)
        #expect(Set(all.map(\.id)) == ["n1", "t1"])
        #expect(try await store.search(text: "checkout", kind: .task, limit: 10).map(\.id) == ["t1"])
        #expect(try await store.search(text: "nothing", kind: nil, limit: 10).isEmpty)
    }

    @Test func persistsAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-\(UUID().uuidString).store")
        do {
            let store = PocketStore(modelContainer: try PocketStore.fileContainer(url: url))
            try await store.saveNote(id: "p1", title: "persisted", body: "persisted", now: t0)
        }
        let reopened = PocketStore(modelContainer: try PocketStore.fileContainer(url: url))
        #expect(try await reopened.note(id: "p1")?.title == "persisted")
    }

    @Test func quotesAndBackslashesRoundTrip() async throws {
        let store = try makeMemoryStore()
        let title = "Bob's \"plan\" \\ draft"
        try await store.saveNote(id: "q", title: title, body: title, now: t0)
        #expect(try await store.note(id: "q")?.title == title)
    }
}

@Suite struct ToolExecutorTests {
    private func executor(_ store: PocketStore, tools: Set<String>? = nil, types: Set<String>? = nil) -> ToolExecutor {
        ToolExecutor(store: store, timeZone: utc, allowedTools: tools, allowedTypes: types)
    }

    @Test func validTaskBatchCreatesTasks() async throws {
        let store = try makeMemoryStore()
        let reply = #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Call the landlord","due":"2026-11-27T09:00:00"}},{"tool":"remember","args":{"type":"Task","title":"Buy milk"}}],"say":"Added two tasks."}"#
        let outcome = await executor(store).run(reply: reply, now: t0)

        #expect(outcome.committed)
        #expect(outcome.issues.isEmpty)
        #expect(outcome.say == "Added two tasks.")
        #expect(outcome.changedIds.count == 2)
        #expect(try await store.openTasks().count == 2)
    }

    /// One bad call in a batch means nothing is written, and each reason is reported.
    @Test func oneRejectedCallWritesNothing() async throws {
        let store = try makeMemoryStore()
        let reply = #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Good"}},{"tool":"remember","args":{"type":"Task","title":"  "}}],"say":"ok"}"#
        let outcome = await executor(store).run(reply: reply, now: t0)

        #expect(!outcome.committed)
        #expect(outcome.issues == ["call 2 (remember): Task needs a title"])
        #expect(try await store.openTasks().isEmpty)
    }

    @Test func rejectsEachBadFieldWithItsReason() async throws {
        let store = try makeMemoryStore()
        let cases: [(String, String)] = [
            (#"{"calls":[{"tool":"remember","args":{"title":"x"}}],"say":""}"#, "remember needs a type"),
            (#"{"calls":[{"tool":"remember","args":{"type":"Note","title":"x"}}],"say":""}"#, "type must be Task, not Note"),
            (#"{"calls":[{"tool":"remember","args":{"type":"Task","title":"x","due":"tomorrow"}}],"say":""}"#,
             "due must be an ISO local date-time, e.g. 2026-11-27T09:00:00"),
            (#"{"calls":[{"tool":"remember","args":{"type":"Task","title":"x","about":"ghost"}}],"say":""}"#,
             "about must be the id of a saved note"),
            (#"{"calls":[{"tool":"remember","args":{"id":"t1","type":"Task","title":"x"}}],"say":""}"#,
             "remember creates new items; leave out id"),
            (#"{"calls":[{"tool":"delete","args":{}}],"say":""}"#, "unknown tool delete"),
        ]
        for (reply, reason) in cases {
            let outcome = await executor(store).run(reply: reply, now: t0)
            #expect(!outcome.committed, "should be rejected: \(reply)")
            #expect(outcome.issues.contains { $0.hasSuffix(reason) }, "reason \"\(reason)\" missing from \(outcome.issues)")
        }
        #expect(try await store.openTasks().isEmpty)
    }

    @Test func aboutAcceptsASavedNote() async throws {
        let store = try makeMemoryStore()
        try await store.saveNote(id: "n1", title: "Landlord", body: "Call", now: t0)
        let reply = #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Call","about":"n1"}}],"say":"ok"}"#
        let outcome = await executor(store).run(reply: reply, now: t0)
        #expect(outcome.committed)
        let task = try #require(try await store.openTasks().first)
        #expect(task.about == "n1")
    }

    /// The task step may only create Tasks, and may not read or write anything else.
    @Test func stepAllowListsBlockOtherToolsAndTypes() async throws {
        let store = try makeMemoryStore()
        let taskStep = executor(store, tools: ["remember"], types: ["Task"])
        let recallCall = await taskStep.run(reply: #"{"calls":[{"tool":"recall","args":{"text":"x"}}],"say":""}"#, now: t0)
        #expect(recallCall.issues == ["call 1 (recall): tool not allowed in this step"])

        let noteCall = await taskStep.run(reply: #"{"calls":[{"tool":"remember","args":{"type":"Note","title":"x"}}],"say":""}"#, now: t0)
        #expect(!noteCall.committed)
        #expect(try await store.recentNotes(limit: 10).isEmpty)
    }

    @Test func answerStepCanReadButNotWrite() async throws {
        let store = try makeMemoryStore()
        try await store.addTasks([NewTask(id: "t1", title: "Call landlord",
                                          due: DateParsing.parse("2026-11-27T09:00:00", in: utc), about: nil)], now: t0)
        let answer = executor(store, tools: ["recall", "due"])

        let read = await answer.run(reply: #"{"calls":[{"tool":"recall","args":{"text":"landlord"}}],"say":"Found it."}"#, now: t0)
        #expect(read.committed)
        #expect(read.results.count == 1)
        #expect(read.changedIds.isEmpty)

        let write = await answer.run(reply: #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"x"}}],"say":""}"#, now: t0)
        #expect(!write.committed)
        #expect(try await store.openTasks().count == 1, "the answer step wrote nothing")
    }

    @Test func dueReturnsTasksBeforeTheTime() async throws {
        let store = try makeMemoryStore()
        try await store.addTasks([NewTask(id: "t1", title: "Call landlord",
                                          due: DateParsing.parse("2026-11-27T09:00:00", in: utc), about: nil)], now: t0)
        let outcome = await executor(store, tools: ["due"]).run(
            reply: #"{"calls":[{"tool":"due","args":{"before":"2026-11-28T00:00:00"}}],"say":"ok"}"#, now: t0)
        #expect(outcome.results.count == 1)
    }

    @Test func malformedReplyIsRejectedWithItsReason() {
        guard case .failure(let problem) = ToolExecutor.parseReply(StepEval.malformed) else {
            Issue.record("the malformed reply parsed")
            return
        }
        #expect(problem.message.hasPrefix("reply is not valid JSON: "), "reason: \(problem.message)")
    }

    @Test func replyWithNeitherCallsNorSayIsRejected() async throws {
        let store = try makeMemoryStore()
        let outcome = await executor(store).run(reply: #"{"intents":["note"]}"#, now: t0)
        #expect(!outcome.committed)
        #expect(outcome.issues == ["reply has neither calls nor say"])
    }
}
