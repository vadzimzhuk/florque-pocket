import Foundation
import Testing
@testable import florque_pocket

@Suite(.serialized) struct SwiftDataGraphStoreTests {
    private func note(_ id: String, _ title: String) -> DynamicNode {
        DynamicNode(id: id, className: "Note", props: ["title": .string(title), "status": .string("proposed")])
    }

    @Test func roundTripsNodesAndEdges() async throws {
        let store = try SwiftDataGraphStore(inMemory: true)
        try await store.apply([
            .upsert(note("a", "first")),
            .upsert(note("b", "second")),
            .link(DynamicEdge(from: "a", slot: "relates_to", to: "b")),
        ])
        let snap = try await store.read()
        #expect(snap.nodes["a"]?.props["title"] == .string("first"))
        #expect(snap.edges == [DynamicEdge(from: "a", slot: "relates_to", to: "b")])
    }

    @Test func failedBatchLeavesNothing() async throws {
        let store = try SwiftDataGraphStore(inMemory: true)
        try await store.apply([.upsert(note("keep", "kept"))])
        await #expect(throws: SwiftDataGraphStoreError.missingEndpoint(from: "keep", to: "missing")) {
            try await store.apply([
                .upsert(note("new", "should roll back")),
                .link(DynamicEdge(from: "keep", slot: "relates_to", to: "missing")),
            ])
        }
        let snap = try await store.read()
        #expect(snap.nodes["new"] == nil)
        #expect(snap.nodes["keep"] != nil)
    }

    @Test func persistsAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString).store")
        do {
            let store = try SwiftDataGraphStore(url: url)
            try await store.apply([.upsert(note("p", "persisted"))])
        }
        let reopened = try SwiftDataGraphStore(url: url)
        #expect(try await reopened.read().nodes["p"]?.title == "persisted")
    }

    @Test func unlinkAndRemove() async throws {
        let store = try SwiftDataGraphStore(inMemory: true)
        try await store.apply([
            .upsert(note("x", "x")), .upsert(note("y", "y")),
            .link(DynamicEdge(from: "x", slot: "relates_to", to: "y")),
        ])
        try await store.apply([.unlink(DynamicEdge(from: "x", slot: "relates_to", to: "y"))])
        #expect(try await store.read().edges.isEmpty)
        try await store.apply([.remove(id: "y")])
        #expect(try await store.read().nodes["y"] == nil)
    }

    @Test func quotesAndBackslashesRoundTrip() async throws {
        let store = try SwiftDataGraphStore(inMemory: true)
        let title = "Bob's \"plan\" \\ draft"
        try await store.apply([.upsert(note("q", title))])
        #expect(try await store.read().nodes["q"]?.title == title)
    }

    /// Behaviour measurement: 2,000 nodes with 1,999 links in one batch.
    @Test func benchmarkBatchWrite() async throws {
        let store = try SwiftDataGraphStore(inMemory: true)
        var changes: [GraphChange] = []
        for i in 0..<2000 { changes.append(.upsert(note("n\(i)", "note \(i)"))) }
        for i in 1..<2000 { changes.append(.link(DynamicEdge(from: "n\(i)", slot: "relates_to", to: "n\(i - 1)"))) }
        let started = Date()
        try await store.apply(changes)
        let writeSeconds = Date().timeIntervalSince(started)
        let readStart = Date()
        let snap = try await store.read()
        let readSeconds = Date().timeIntervalSince(readStart)
        print("BENCH nodes=\(snap.nodes.count) edges=\(snap.edges.count) write=\(writeSeconds)s read=\(readSeconds)s")
        #expect(snap.nodes.count == 2000)
        #expect(snap.edges.count == 1999)
    }
}
