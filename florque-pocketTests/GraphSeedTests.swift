// Purpose: checks the default node and edge types seeded on first launch.
//
// Testing: seeds an in-memory store, then seeds it again, and checks the counts, the keys, the locked on-device
// flags on person and feeling, and that an edit made by the user survives a second seed.

import Foundation
import SwiftData
import Testing
@testable import florque_pocket

@MainActor @Suite struct GraphSeedTests {
    @Test func seedInsertsEveryDefaultOnce() async throws {
        let container = try PocketStore.memoryContainer()
        let store = PocketStore(modelContainer: container)
        try await store.seedGraphDefaults()
        try await store.seedGraphDefaults()

        let context = ModelContext(container)
        let nodeTypes = try context.fetch(FetchDescriptor<NodeType>())
        let edgeTypes = try context.fetch(FetchDescriptor<EdgeType>())
        let expectedNodeKeys = Set(GraphDefaults.nodeTypes.map(\.key))
        let expectedEdgeKeys = Set(GraphDefaults.edgeTypes.map(\.key))
        let gotNodeKeys = Set(nodeTypes.map(\.key))
        let gotEdgeKeys = Set(edgeTypes.map(\.key))
        #expect(nodeTypes.count == expectedNodeKeys.count)
        #expect(edgeTypes.count == expectedEdgeKeys.count)
        #expect(gotNodeKeys == expectedNodeKeys)
        #expect(gotEdgeKeys == expectedEdgeKeys)
        let allDefault = nodeTypes.allSatisfy { $0.isDefault }
        #expect(allDefault)
    }

    @Test func personAndFeelingAreOnDeviceOnly() throws {
        let onDevice = Set(GraphDefaults.nodeTypes.filter(\.onDeviceOnly).map(\.key))
        #expect(onDevice == ["person", "feeling"])
    }

    @Test func eventAndTaskScheduleReminders() throws {
        let reminders = Set(GraphDefaults.nodeTypes.filter(\.schedulesReminder).map(\.key))
        #expect(reminders == ["event", "task"])
    }

    @Test func seedKeepsUserEditsToAnExistingType() async throws {
        let container = try PocketStore.memoryContainer()
        let store = PocketStore(modelContainer: container)
        try await store.seedGraphDefaults()

        let context = ModelContext(container)
        let person = try #require(try context.fetch(FetchDescriptor<NodeType>(
            predicate: #Predicate { $0.key == "person" })).first)
        person.enabled = false
        try context.save()

        try await store.seedGraphDefaults()
        let after = try #require(try ModelContext(container).fetch(FetchDescriptor<NodeType>(
            predicate: #Predicate { $0.key == "person" })).first)
        #expect(after.enabled == false)
    }
}
