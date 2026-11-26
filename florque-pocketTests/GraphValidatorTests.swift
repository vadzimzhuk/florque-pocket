// Purpose: checks each validation rule in brief section 8 and the entity resolution that runs before a create.
//
// Testing: each test seeds an in-memory store, optionally applies a first batch, then validates a second batch
// against the resulting snapshot. Times are fixed in UTC.

import Foundation
import SwiftData
import Testing
@testable import florque_pocket

@MainActor @Suite struct GraphValidatorTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func fixture() async throws -> (PocketStore, Date) {
        let container = try PocketStore.memoryContainer()
        let store = PocketStore(modelContainer: container)
        try await store.seedGraphDefaults()
        let now = try #require(DateParsing.parse("2026-11-25T10:00:00", in: utc))
        return (store, now)
    }

    private func validate(_ store: PocketStore, nodes: [ProposedNode], edges: [ProposedEdge] = [],
                          now: Date, timeZone: TimeZone) async throws -> ValidatedGraphBatch {
        GraphValidator.validate(nodes: nodes, edges: edges, against: try await store.snapshot(), now: now,
                                timeZone: timeZone)
    }

    @Test func unknownTypeIsRejectedAndTheRestOfTheBatchGoesThrough() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "spaceship", title: "Apollo"),
            ProposedNode(ref: "b", typeKey: "note", title: "Keep me"),
        ], now: now, timeZone: utc)
        #expect(batch.rejections == [GraphRejection(item: "a", reason: .unknownType("spaceship"))])
        #expect(batch.creates.map(\.title) == ["Keep me"])
    }

    @Test func disabledTypeIsRejected() async throws {
        let (store, now) = try await fixture()
        try await store.setNodeTypeEnabled(key: "note", enabled: false)
        let batch = try await validate(store, nodes: [ProposedNode(ref: "a", typeKey: "note", title: "Hi")],
                                       now: now, timeZone: utc)
        #expect(batch.rejections == [GraphRejection(item: "a", reason: .disabledType("note"))])
        #expect(batch.creates.isEmpty)
    }

    @Test func titleAndBodyLimitsAreEnforced() async throws {
        let (store, now) = try await fixture()
        let long = String(repeating: "t", count: GraphValidator.maxTitleLength + 1)
        let body = String(repeating: "b", count: GraphValidator.maxBodyLength + 1)
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "empty", typeKey: "note", title: "   "),
            ProposedNode(ref: "long", typeKey: "note", title: long),
            ProposedNode(ref: "body", typeKey: "note", title: "Ok", body: body),
        ], now: now, timeZone: utc)
        #expect(batch.rejections.map(\.reason) == [
            .emptyTitle,
            .titleTooLong(limit: GraphValidator.maxTitleLength),
            .bodyTooLong(limit: GraphValidator.maxBodyLength),
        ])
        #expect(batch.creates.isEmpty)
    }

    @Test func unparseableDueIsRejectedForAnyType() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "event", title: "Dentist", dueRaw: "next tuesday-ish"),
        ], now: now, timeZone: utc)
        #expect(batch.rejections == [GraphRejection(item: "a", reason: .dueUnparseable("next tuesday-ish"))])
    }

    @Test func reminderTypeRejectsADueTimeMoreThanADayInThePast() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "old", typeKey: "event", title: "Old", dueRaw: "2026-11-20T09:00:00"),
            ProposedNode(ref: "recent", typeKey: "event", title: "Recent", dueRaw: "2026-11-25T08:00:00"),
        ], now: now, timeZone: utc)
        #expect(batch.rejections == [GraphRejection(item: "old", reason: .dueTooOld)])
        #expect(batch.creates.first?.dueAt != nil)
    }

    @Test func nonReminderTypeKeepsAnOldDueTime() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "n", typeKey: "note", title: "Old note", dueRaw: "2020-01-01T00:00:00"),
        ], now: now, timeZone: utc)
        #expect(batch.rejections.isEmpty)
        #expect(batch.creates.first?.dueAt != nil)
    }

    @Test func edgeEndpointsMustExist() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [ProposedNode(ref: "a", typeKey: "note", title: "A")],
                                       edges: [ProposedEdge(typeKey: "mentions", from: "a", to: "ghost")],
                                       now: now, timeZone: utc)
        #expect(batch.rejections == [GraphRejection(item: "a → ghost", reason: .missingEndpoint("ghost"))])
        #expect(batch.edges.isEmpty)
    }

    @Test func selfLoopIsRejected() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [ProposedNode(ref: "a", typeKey: "note", title: "A")],
                                       edges: [ProposedEdge(typeKey: "relates_to", from: "a", to: "a")],
                                       now: now, timeZone: utc)
        #expect(batch.rejections.map(\.reason) == [.selfLoop])
    }

    @Test func endpointTypesFollowAllowedFromAndTo() async throws {
        let (store, now) = try await fixture()
        // participates allows person -> event only.
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "n", typeKey: "note", title: "Not a person"),
            ProposedNode(ref: "e", typeKey: "event", title: "Interview"),
        ], edges: [ProposedEdge(typeKey: "participates", from: "n", to: "e")], now: now, timeZone: utc)
        #expect(batch.rejections.map(\.reason) == [.endpointNotAllowed("note")])
        #expect(batch.edges.isEmpty)
    }

    @Test func existingEdgeIsNotDuplicated() async throws {
        let (store, now) = try await fixture()
        let first = try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "note", title: "A"),
            ProposedNode(ref: "b", typeKey: "note", title: "B"),
        ], edges: [ProposedEdge(typeKey: "mentions", from: "a", to: "b")], now: now, timeZone: utc)
        _ = try await store.apply(first, now: now)

        let aId = try #require(try await store.nodes().first { $0.title == "A" }?.id)
        let bId = try #require(try await store.nodes().first { $0.title == "B" }?.id)
        let again = try await validate(store, nodes: [], edges: [
            ProposedEdge(typeKey: "mentions", from: aId.uuidString, to: bId.uuidString),
        ], now: now, timeZone: utc)
        #expect(again.rejections.map(\.reason) == [.duplicateEdge])
    }

    @Test func symmetricEdgeIsNotDuplicatedInReverse() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "note", title: "A"),
            ProposedNode(ref: "b", typeKey: "note", title: "B"),
        ], edges: [
            ProposedEdge(typeKey: "relates_to", from: "a", to: "b"),
            ProposedEdge(typeKey: "relates_to", from: "b", to: "a"),
        ], now: now, timeZone: utc)
        #expect(batch.edges.count == 1)
        #expect(batch.rejections.map(\.reason) == [.duplicateEdge])
    }

    @Test func sameTitleInOneBatchBecomesOneNode() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "first", typeKey: "person", title: "Anna"),
            ProposedNode(ref: "second", typeKey: "person", title: "anna"),
        ], now: now, timeZone: utc)
        #expect(batch.creates.count == 1)
        #expect(batch.rejections.isEmpty)
    }

    @Test func existingNodeIsMatchedByTitleAndGainsAnAlias() async throws {
        let (store, now) = try await fixture()
        _ = try await store.apply(try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "person", title: "Anna"),
        ], now: now, timeZone: utc), now: now)

        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "person", title: "Anna", body: "nervous about the interview", aliases: ["Anna Smith"]),
        ], now: now, timeZone: utc)
        #expect(batch.creates.isEmpty)
        let update = try #require(batch.updates.first)
        #expect(update.addAliases == ["Anna Smith"])
        #expect(update.body == "nervous about the interview")
    }

    @Test func sameTitleWithNothingNewIsNotAnUpdate() async throws {
        let (store, now) = try await fixture()
        _ = try await store.apply(try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "person", title: "Anna"),
        ], now: now, timeZone: utc), now: now)
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "person", title: "ANNA"),
        ], now: now, timeZone: utc)
        #expect(batch.isEmpty)
    }

    @Test func matchIdIsUsedOnlyWhenItExistsWithTheSameType() async throws {
        let (store, now) = try await fixture()
        _ = try await store.apply(try await validate(store, nodes: [
            ProposedNode(ref: "a", typeKey: "person", title: "Anna"),
        ], now: now, timeZone: utc), now: now)
        let annaId = try #require(try await store.nodes().first?.id)

        let wrongType = try await validate(store, nodes: [
            ProposedNode(ref: "x", typeKey: "note", title: "Something else", matchId: annaId),
        ], now: now, timeZone: utc)
        #expect(wrongType.creates.map(\.title) == ["Something else"])
        #expect(wrongType.updates.isEmpty)

        let unknown = try await validate(store, nodes: [
            ProposedNode(ref: "x", typeKey: "person", title: "Someone new", matchId: UUID()),
        ], now: now, timeZone: utc)
        #expect(unknown.creates.map(\.title) == ["Someone new"])
    }

    @Test func edgeToANodeCreatedInTheSameBatchUsesItsNewId() async throws {
        let (store, now) = try await fixture()
        let batch = try await validate(store, nodes: [
            ProposedNode(ref: "anna", typeKey: "person", title: "Anna"),
            ProposedNode(ref: "interview", typeKey: "event", title: "Interview", dueRaw: "2026-11-26T15:00:00"),
        ], edges: [ProposedEdge(typeKey: "participates", from: "anna", to: "interview")],
           now: now, timeZone: utc)
        let annaId = try #require(batch.creates.first { $0.title == "Anna" }?.id)
        let eventId = try #require(batch.creates.first { $0.title == "Interview" }?.id)
        #expect(batch.rejections.isEmpty)
        #expect(batch.edges.first?.typeKey == "participates")
        #expect(batch.edges.first?.fromId == annaId)
        #expect(batch.edges.first?.toId == eventId)
    }
}
