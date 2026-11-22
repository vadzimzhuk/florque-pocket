import Foundation
import Testing
@testable import florque_pocket

// Purpose: checks the `Assistant` end to end on the intent workflow, with a scripted model and fake reminders,
// against a real SwiftData store held in memory. Each test asserts what was written to the store objects, not
// what the model said.
//
// Testing approach: the model is scripted, so each test controls exactly which replies the workflow sees, and the
// model call count shows which steps ran. Stores are fresh per test.

/// Scripted model: returns the queued replies in order and records each call.
@MainActor
class FakeModel: ModelAdapter {
    private var queue: [(String, Route)]
    private(set) var calls: [(user: String, policy: RoutePolicy)] = []

    init(_ replies: [(String, Route)]) { queue = replies }

    func generate(system: String, user: String, policy: RoutePolicy) async throws -> ModelReply {
        calls.append((user, policy))
        guard !queue.isEmpty else { throw URLError(.cannotConnectToHost) }
        let (text, route) = queue.removeFirst()
        return ModelReply(text: text, route: route, modelName: "fake", seconds: 0.5)
    }
}

/// Fake reminders: records what was asked and returns a predictable identifier.
@MainActor
class FakeReminders: RemindersAdapter {
    private(set) var created: [(String, Date)] = []
    func createReminder(title: String, due: Date) async throws -> String {
        created.append((title, due))
        return "ek-\(created.count)"
    }
}

/// A fresh in-memory store for one test.
func makeMemoryStore() throws -> PocketStore {
    PocketStore(modelContainer: try PocketStore.memoryContainer())
}

private let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)

@Suite struct AssistantTests {
    private func make(_ model: FakeModel, store: PocketStore) -> Assistant {
        Assistant(store: store, model: model, clock: { fixedNow }, timeZone: TimeZone(identifier: "UTC")!)
    }

    /// A task already in the store, as an earlier turn left it.
    private func seedTask(_ store: PocketStore) async throws {
        try await store.addTasks([NewTask(id: "t-1", title: "Call landlord",
                                          due: DateParsing.parse("2026-11-27T09:00:00", in: TimeZone(identifier: "UTC")!),
                                          about: nil)], now: fixedNow)
    }

    @Test func intentSavesAStatementAsANoteOnly() async throws {
        let store = try makeMemoryStore()
        let model = await FakeModel([(#"{"intents":["note"]}"#, .onDevice)])
        let turn = try await make(model, store: store).handle("I have a meeting with Anna on Monday.", policy: .auto)

        #expect(try await store.recentNotes(limit: 10).count == 1)
        #expect(try await store.openTasks().isEmpty)
        #expect(turn.intents == [.note])
        #expect(await model.calls.count == 1, "a note needs only the classifier")
    }

    @Test func acceptActivatesAndSchedulesReminder() async throws {
        let store = try makeMemoryStore()
        try await seedTask(store)
        let reminders = await FakeReminders()
        try await make(await FakeModel([]), store: store).accept(taskId: "t-1", reminders: reminders)

        let task = try #require(try await store.task(id: "t-1"))
        #expect(task.status == .active)
        #expect(task.eventId == "ek-1")
        #expect(await reminders.created.count == 1)
    }

    @Test func dismissDropsTask() async throws {
        let store = try makeMemoryStore()
        try await seedTask(store)
        try await make(await FakeModel([]), store: store).dismiss(taskId: "t-1")
        #expect(try await store.task(id: "t-1")?.status == .dropped)
        #expect(try await store.openTasks().isEmpty, "a dropped task leaves the open list")
    }

    /// The digest is what the answer prompt sees: open tasks and recent notes, and nothing dropped.
    @Test func digestListsOpenTasksAndNotes() async throws {
        let store = try makeMemoryStore()
        try await seedTask(store)
        try await store.saveNote(id: "n-1", title: "Idea", body: "Idea body", now: fixedNow)
        let tasks = try await store.openTasks()
        let notes = try await store.recentNotes(limit: 20)
        let text = Digest.build(tasks: tasks, notes: notes, timeZone: TimeZone(identifier: "UTC")!)
        #expect(text.contains("Task t-1 | Call landlord | due 2026-11-27T09:00:00"))
        #expect(text.contains("Note n-1 | Idea"))
    }
}
