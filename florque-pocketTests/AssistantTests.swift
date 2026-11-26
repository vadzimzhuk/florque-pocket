import Foundation
import Testing
@testable import florque_pocket

// Purpose: test doubles shared by the test suites: a scripted model, fake reminders, and a fresh in-memory store.
// The workflow tests that use them live in `CERTests` and `GraphQueriesTests`.
//
// Testing: not a suite; it only provides the doubles.

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
    private(set) var deleted: [String] = []
    func createReminder(title: String, due: Date) async throws -> String {
        created.append((title, due))
        return "ek-\(created.count)"
    }
    func deleteReminder(identifier: String) async throws {
        deleted.append(identifier)
    }
}

/// A fresh in-memory store for one test.
func makeMemoryStore() throws -> PocketStore {
    PocketStore(modelContainer: try PocketStore.memoryContainer())
}
