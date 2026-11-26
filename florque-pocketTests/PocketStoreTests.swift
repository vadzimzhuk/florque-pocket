import Foundation
import Testing
@testable import florque_pocket

// Purpose: checks the SwiftData layer (`PocketStore`) and the tool executor that writes through it.
//
// Testing approach:
// - PocketStoreTests: each operation on an in-memory container, plus a file-backed store that is reopened, since
//   persistence is the one thing an in-memory container cannot show.
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
