// Purpose: checks the graph store: type editing and its caps, reassignment when a custom type is deleted, applying a
// batch, undoing it, and the one-time import of the old notes and tasks.
//
// Testing: each test runs on a fresh in-memory container. The legacy import uses its own UserDefaults suite.

import Foundation
import SwiftData
import Testing
@testable import florque_pocket

@MainActor @Suite struct GraphStoreTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func fixture() async throws -> (PocketStore, ModelContainer, Date) {
        let container = try PocketStore.memoryContainer()
        let store = PocketStore(modelContainer: container)
        try await store.seedGraphDefaults()
        let now = try #require(DateParsing.parse("2026-11-25T10:00:00", in: utc))
        return (store, container, now)
    }

    /// Asserts that `operation` throws exactly `expected`.
    private func expectThrows(_ expected: GraphStoreError, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("expected \(expected) but nothing was thrown")
        } catch let error as GraphStoreError {
            #expect(error == expected)
        } catch {
            Issue.record("expected \(expected) but got \(error)")
        }
    }

    private func applyNode(_ store: PocketStore, now: Date, typeKey: String, title: String,
                           edges: [ProposedEdge] = [], nodes extra: [ProposedNode] = []) async throws -> GraphChangeset {
        let batch = GraphValidator.validate(nodes: [ProposedNode(ref: "n", typeKey: typeKey, title: title)] + extra,
                                            edges: edges, against: try await store.snapshot(), now: now, timeZone: utc)
        return try await store.apply(batch, now: now)
    }

    // MARK: node types

    @Test func customNodeTypeGetsASlugKeyAndIsNotDefault() async throws {
        let (store, _, _) = try await fixture()
        let key = try await store.saveNodeType(NodeTypeDraft(name: "Recipe Book", typeDescription: "A recipe to keep"))
        #expect(key == "recipe_book")
        let created = try #require(try await store.nodeTypes().first { $0.key == key })
        #expect(created.isDefault == false)
        #expect(created.name == "Recipe Book")
    }

    @Test func aSecondTypeWithTheSameKeyIsRefused() async throws {
        let (store, _, _) = try await fixture()
        try await store.saveNodeType(NodeTypeDraft(name: "Recipe", typeDescription: "A recipe"))
        await expectThrows(.keyTaken("recipe")) {
            try await store.saveNodeType(NodeTypeDraft(name: "recipe", typeDescription: "Again"))
        }
    }

    @Test func customNodeTypesAreCappedAtTen() async throws {
        let (store, _, _) = try await fixture()
        for index in 1...GraphDefaults.maxCustomNodeTypes {
            try await store.saveNodeType(NodeTypeDraft(name: "Kind \(index)", typeDescription: "Kind \(index)"))
        }
        await expectThrows(.capReached(kind: "node type", limit: GraphDefaults.maxCustomNodeTypes)) {
            try await store.saveNodeType(NodeTypeDraft(name: "Eleventh", typeDescription: "Too many"))
        }
    }

    @Test func descriptionLongerThanTheLimitIsRefused() async throws {
        let (store, _, _) = try await fixture()
        let long = String(repeating: "d", count: GraphDefaults.maxDescriptionLength + 1)
        await expectThrows(.descriptionTooLong(limit: GraphDefaults.maxDescriptionLength)) {
            try await store.saveNodeType(NodeTypeDraft(name: "Long", typeDescription: long))
        }
    }

    @Test func personStaysOnDeviceWhateverTheDraftSays() async throws {
        let (store, _, _) = try await fixture()
        try await store.saveNodeType(NodeTypeDraft(key: "person", name: "Person", typeDescription: "Someone",
                                                   onDeviceOnly: false, schedulesReminder: false))
        let person = try #require(try await store.nodeTypes().first { $0.key == "person" })
        #expect(person.onDeviceOnly == true)
    }

    @Test func defaultNodeTypeCannotBeDeleted() async throws {
        let (store, _, _) = try await fixture()
        await expectThrows(.defaultTypeNotDeletable("event")) { try await store.deleteNodeType(key: "event") }
    }

    @Test func deletingACustomNodeTypeMovesItsNodesToNoteAndCleansEdgeTypes() async throws {
        let (store, _, now) = try await fixture()
        try await store.saveNodeType(NodeTypeDraft(name: "Recipe", typeDescription: "A recipe"))
        try await store.saveEdgeType(EdgeTypeDraft(name: "Cooks", inverseName: "Cooked by", typeDescription: "Cooks it",
                                                   fromNodeKeys: ["recipe"], toNodeKeys: []))
        _ = try await applyNode(store, now: now, typeKey: "recipe", title: "Pancakes")

        try await store.deleteNodeType(key: "recipe")

        let node = try #require(try await store.nodes().first)
        #expect(node.typeKey == "note")
        let cooks = try #require(try await store.edgeTypes().first { $0.name == "Cooks" })
        #expect(cooks.fromNodeKeys.isEmpty)
        #expect(try await store.nodeTypes().contains { $0.key == "recipe" } == false)
    }

    @Test func disablingANodeTypeIsStored() async throws {
        let (store, _, _) = try await fixture()
        try await store.setNodeTypeEnabled(key: "person", enabled: false)
        let person = try #require(try await store.nodeTypes().first { $0.key == "person" })
        #expect(person.enabled == false)
    }

    // MARK: edge types

    @Test func edgeTypeWithAnUnknownEndpointIsRefused() async throws {
        let (store, _, _) = try await fixture()
        await expectThrows(.unknownNodeType("ghost")) {
            try await store.saveEdgeType(EdgeTypeDraft(name: "Haunts", inverseName: "Haunted by",
                                                       typeDescription: "Haunts", fromNodeKeys: ["ghost"]))
        }
    }

    @Test func deletingACustomEdgeTypeMovesItsEdgesToRelatesTo() async throws {
        let (store, _, now) = try await fixture()
        try await store.saveEdgeType(EdgeTypeDraft(name: "Cooks", inverseName: "Cooked by", typeDescription: "Cooks it"))
        let batch = GraphValidator.validate(nodes: [
            ProposedNode(ref: "a", typeKey: "note", title: "A"),
            ProposedNode(ref: "b", typeKey: "note", title: "B"),
        ], edges: [ProposedEdge(typeKey: "cooks", from: "a", to: "b")],
            against: try await store.snapshot(), now: now, timeZone: utc)
        #expect(batch.rejections.isEmpty)
        _ = try await store.apply(batch, now: now)

        try await store.deleteEdgeType(key: "cooks")
        let edge = try #require(try await store.edges().first)
        #expect(edge.typeKey == "relates_to")
    }

    @Test func defaultEdgeTypeCannotBeDeleted() async throws {
        let (store, _, _) = try await fixture()
        await expectThrows(.defaultTypeNotDeletable("mentions")) { try await store.deleteEdgeType(key: "mentions") }
    }

    // MARK: apply and undo

    @Test func applyWritesTheBatchAndUndoReversesIt() async throws {
        let (store, _, now) = try await fixture()
        let first = GraphValidator.validate(nodes: [
            ProposedNode(ref: "anna", typeKey: "person", title: "Anna"),
            ProposedNode(ref: "interview", typeKey: "event", title: "Interview", dueRaw: "2026-11-26T15:00:00"),
        ], edges: [ProposedEdge(typeKey: "participates", from: "anna", to: "interview")],
            against: try await store.snapshot(), now: now, timeZone: utc)
        let created = try await store.apply(first, now: now)
        #expect(created.createdNodeIds.count == 2)
        #expect(created.createdEdgeIds.count == 1)
        #expect(try await store.nodes().count == 2)
        #expect(try await store.edges().count == 1)

        let anna = try #require(try await store.nodes().first { $0.title == "Anna" })
        let second = GraphValidator.validate(nodes: [
            ProposedNode(ref: "a", typeKey: "person", title: "Anna", body: "nervous"),
        ], against: try await store.snapshot(), now: now, timeZone: utc)
        let updated = try await store.apply(second, now: now)
        #expect(updated.previousNodes.first?.body == "")
        #expect(try await store.node(id: anna.id)?.body == "nervous")

        try await store.undo(updated)
        #expect(try await store.node(id: anna.id)?.body == "")

        try await store.undo(created)
        #expect(try await store.nodes().isEmpty)
        #expect(try await store.edges().isEmpty)
    }

    @Test func undoRemovesEdgesThatTouchANodeItCreated() async throws {
        let (store, _, now) = try await fixture()
        let seed = try await applyNode(store, now: now, typeKey: "note", title: "Existing")
        let existing = try #require(seed.createdNodeIds.first)
        let batch = GraphValidator.validate(nodes: [ProposedNode(ref: "new", typeKey: "note", title: "New")],
                                            edges: [ProposedEdge(typeKey: "mentions", from: "new", to: existing.uuidString)],
                                            against: try await store.snapshot(), now: now, timeZone: utc)
        let changeset = try await store.apply(batch, now: now)
        try await store.undo(changeset)
        #expect(try await store.edges().isEmpty)
        #expect(try await store.nodes().map(\.title) == ["Existing"])
    }

    // MARK: legacy import

    @Test func legacyNotesAndTasksAreImportedOnceAndLinked() async throws {
        let (store, container, _) = try await fixture()
        let context = ModelContext(container)
        let noteId = UUID().uuidString
        let note = Note(id: noteId, title: "Old note", body: "text", status: .active,
                        createdAt: Date(), updatedAt: Date())
        let task = PocketTask(id: UUID().uuidString, title: "Pay rent", status: .active,
                              due: Date(), eventId: nil, about: noteId, createdAt: Date(), updatedAt: Date())
        let loose = PocketTask(id: UUID().uuidString, title: "Buy milk", status: .dropped,
                               due: nil, eventId: nil, about: nil, createdAt: Date(), updatedAt: Date())
        context.insert(note)
        context.insert(task)
        context.insert(loose)
        try context.save()

        let defaults = try #require(UserDefaults(suiteName: "GraphStoreTests.\(UUID().uuidString)"))
        let copied = try await store.importLegacyIfNeeded(defaults: defaults)
        #expect(copied == 3)

        let nodes = try await store.nodes()
        #expect(nodes.first { $0.title == "Old note" }?.typeKey == "note")
        #expect(nodes.first { $0.title == "Pay rent" }?.typeKey == "event")
        #expect(nodes.first { $0.title == "Buy milk" }?.typeKey == "task")
        #expect(nodes.first { $0.title == "Buy milk" }?.status == "archived")
        let edges = try await store.edges()
        #expect(edges.count == 1)
        #expect(edges.first?.typeKey == "follows_up")

        #expect(try await store.importLegacyIfNeeded(defaults: defaults) == 0)
        #expect(try await store.nodes().count == 3)
    }
}
