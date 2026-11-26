// Purpose: checks the graph queries the retrieve tool and the Memory tab use, the link review actions, and that
// undoing a chat turn removes both its graph writes and its reminder.
//
// Testing: in-memory stores with the default types; reminders are `FakeReminders`; the turn is a scripted `FakeModel`.

import Foundation
import SwiftData
import Testing
@testable import florque_pocket

@MainActor @Suite struct GraphQueriesTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func fixture() async throws -> (PocketStore, Date) {
        let store = try makeMemoryStore()
        try await store.seedGraphDefaults()
        return (store, try #require(DateParsing.parse("2026-11-25T10:00:00", in: utc)))
    }

    private func save(_ store: PocketStore, now: Date, _ nodes: [ProposedNode], _ edges: [ProposedEdge] = []) async throws -> GraphChangeset {
        let batch = GraphValidator.validate(nodes: nodes, edges: edges, against: try await store.snapshot(), now: now, timeZone: utc)
        return try await store.apply(batch, now: now)
    }

    @Test func searchMatchesTitlesAliasesAndBodies() async throws {
        let (store, now) = try await fixture()
        _ = try await save(store, now: now, [
            ProposedNode(ref: "a", typeKey: "person", title: "Anna", body: "likes tea", aliases: ["Annie"]),
            ProposedNode(ref: "b", typeKey: "note", title: "Wifi", body: "the code is 4411"),
        ])
        #expect(try await store.searchNodes(text: "annie", typeKey: nil, from: nil, to: nil, limit: 8).map(\.title) == ["Anna"])
        #expect(try await store.searchNodes(text: "tea", typeKey: nil, from: nil, to: nil, limit: 8).map(\.title) == ["Anna"])
        #expect(try await store.searchNodes(text: "4411", typeKey: nil, from: nil, to: nil, limit: 8).map(\.title) == ["Wifi"])
        #expect(try await store.searchNodes(text: nil, typeKey: "person", from: nil, to: nil, limit: 8).count == 1)
    }

    @Test func searchFiltersByDueRange() async throws {
        let (store, now) = try await fixture()
        _ = try await save(store, now: now, [
            ProposedNode(ref: "a", typeKey: "event", title: "Early", dueRaw: "2026-11-26T09:00:00"),
            ProposedNode(ref: "b", typeKey: "event", title: "Late", dueRaw: "2026-12-02T09:00:00"),
        ])
        let from = try #require(DateParsing.parse("2026-11-26T00:00:00", in: utc))
        let to = try #require(DateParsing.parse("2026-11-27T00:00:00", in: utc))
        let found = try await store.searchNodes(text: nil, typeKey: "event", from: from, to: to, limit: 8)
        #expect(found.map(\.title) == ["Early"])
    }

    @Test func strongestNeighbourIsTheMostRecentAcceptedLink() async throws {
        let (store, now) = try await fixture()
        let first = try await save(store, now: now, [
            ProposedNode(ref: "a", typeKey: "person", title: "Anna"),
            ProposedNode(ref: "b", typeKey: "event", title: "Interview", dueRaw: "2026-11-27T10:00:00"),
        ], [ProposedEdge(typeKey: "participates", from: "a", to: "b")])
        let anna = try #require(first.createdNodeIds.first)
        let neighbour = try await store.strongestNeighbour(of: anna)
        #expect(neighbour?.title == "Interview")
        #expect(try await store.strongestNeighbour(of: UUID()) == nil)
    }

    @Test func reviewingALinkAcceptsOrRemovesIt() async throws {
        let (store, now) = try await fixture()
        _ = try await save(store, now: now, [
            ProposedNode(ref: "a", typeKey: "note", title: "A"),
            ProposedNode(ref: "b", typeKey: "note", title: "B"),
        ], [ProposedEdge(typeKey: "mentions", from: "a", to: "b")])
        let edge = try #require(try await store.edges().first)

        try await store.reviewEdge(id: edge.id, accept: true)
        #expect(try await store.edges().first?.status == "accepted")

        try await store.reviewEdge(id: edge.id, accept: false)
        #expect(try await store.edges().isEmpty)
    }

    @Test func undoingATurnRemovesItsNodesAndItsReminder() async throws {
        let container = try PocketStore.memoryContainer()
        let store = PocketStore(modelContainer: container)
        try await store.seedGraphDefaults()
        let reminders = FakeReminders()
        let model = FakeModel([
            (#"{"intent":"record_event","reason":"an event"}"#, .onDevice),
            (#"{"args":{"nodes":[{"ref":"d","type":"event","title":"Dentist","dueAt":"2026-11-27T09:00:00"}]}}"#, .onDevice),
            (#"{"say":"Added the dentist."}"#, .onDevice),
        ])
        let assistant = Assistant(store: store, model: model, clock: { [utc] in
            DateParsing.parse("2026-11-25T10:00:00", in: utc) ?? Date()
        }, timeZone: utc, workflow: .cer, reminders: reminders)

        let turn = try await assistant.handle("dentist tomorrow at nine", policy: .forceOnDevice)
        #expect(try await store.nodes().map(\.title) == ["Dentist"])
        let changeset = try #require(turn.changeset)

        try await assistant.undo(changeset, reminders: reminders)
        #expect(try await store.nodes().isEmpty)
        #expect(reminders.deleted == ["ek-1"])
    }
}
