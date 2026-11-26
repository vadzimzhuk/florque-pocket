// Purpose: checks what the Memory tab shows: the type filter, the search, the link counts, and the grouping of an
// entry's links by link type and direction.
//
// Testing: in-memory store with the default types; nodes and links are written through the validator and store.

import Foundation
import Testing
@testable import florque_pocket

@MainActor @Suite struct MemoryModelTests {
    private let utc = TimeZone(identifier: "UTC")!

    /// Anna (person) participates in an interview (event); a note mentions Anna.
    private func fixture() async throws -> (PocketStore, [String: UUID]) {
        let store = try makeMemoryStore()
        try await store.seedGraphDefaults()
        let now = try #require(DateParsing.parse("2026-11-25T10:00:00", in: utc))
        let batch = GraphValidator.validate(nodes: [
            ProposedNode(ref: "anna", typeKey: "person", title: "Anna"),
            ProposedNode(ref: "interview", typeKey: "event", title: "Interview", dueRaw: "2026-11-27T10:00:00"),
            ProposedNode(ref: "note", typeKey: "note", title: "Ask about the role"),
        ], edges: [
            ProposedEdge(typeKey: "participates", from: "anna", to: "interview"),
            ProposedEdge(typeKey: "mentions", from: "note", to: "anna"),
        ], against: try await store.snapshot(), now: now, timeZone: utc)
        _ = try await store.apply(batch, now: now)
        var ids: [String: UUID] = [:]
        for node in try await store.nodes() { ids[node.title] = node.id }
        return (store, ids)
    }

    @Test func filterAndSearchNarrowTheList() async throws {
        let (store, _) = try await fixture()
        let model = MemoryModel(store: store)
        await model.load()
        #expect(model.visible.count == 3)

        model.typeFilter = "person"
        #expect(model.visible.map(\.title) == ["Anna"])
        model.typeFilter = nil

        model.query = "interv"
        #expect(model.visible.map(\.title) == ["Interview"])
        model.query = "nothing like this"
        #expect(model.visible.isEmpty)
    }

    @Test func linkCountsCountBothEnds() async throws {
        let (store, ids) = try await fixture()
        let model = MemoryModel(store: store)
        await model.load()
        #expect(model.linkCounts[ids["Anna"]!] == 2)
        #expect(model.linkCounts[ids["Interview"]!] == 1)
    }

    @Test func linksAreGroupedWithTheNameOrTheInverseNameByDirection() async throws {
        let (store, ids) = try await fixture()

        let anna = EntryDetailModel(store: store, nodeId: ids["Anna"]!)
        await anna.load()
        let headings = anna.groups.map(\.heading)
        #expect(headings.contains("Participates"), "Anna is the outgoing end")
        #expect(headings.contains("Mentioned in"), "Anna is the incoming end of mentions")

        let interview = EntryDetailModel(store: store, nodeId: ids["Interview"]!)
        await interview.load()
        #expect(interview.groups.map(\.heading) == ["Has participant"])
        #expect(interview.groups.first?.links.first?.node.title == "Anna")
    }

    @Test func proposedLinksCanBeDismissed() async throws {
        let (store, ids) = try await fixture()
        let model = EntryDetailModel(store: store, nodeId: ids["Anna"]!)
        await model.load()
        let link = try #require(model.groups.flatMap(\.links).first)
        await model.review(link, accept: false)
        #expect(try await store.edges().count == 1, "the dismissed link is removed, the other one stays")
    }
}
