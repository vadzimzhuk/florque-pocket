// Purpose: snapshot tests for the type blocks that go into extraction prompts.
//
// Testing: exact text for the default configuration and for a custom one, disabled types leaving both blocks, the
// per-prompt caps, the character budget, and matched types moving to the front.

import Foundation
import SwiftData
import Testing
@testable import florque_pocket

@MainActor @Suite struct GraphPromptBlocksTests {
    private func fixture() async throws -> PocketStore {
        let container = try PocketStore.memoryContainer()
        let store = PocketStore(modelContainer: container)
        try await store.seedGraphDefaults()
        return store
    }

    @Test func defaultNodeBlockMatchesTheSnapshot() async throws {
        let store = try await fixture()
        let block = GraphPromptBlocks.nodeTypesBlock(try await store.nodeTypes())
        #expect(block == """
        - note: Anything worth remembering that fits nothing else
        - event: Something happening at a specific time
        - task: Something the user needs to do
        - person: Someone in the user's life, mentioned by name
        - feeling: How the user says they feel, in their own words
        """)
    }

    @Test func defaultEdgeBlockMatchesTheSnapshot() async throws {
        let store = try await fixture()
        let block = GraphPromptBlocks.edgeTypesBlock(try await store.edgeTypes(), nodeTypes: try await store.nodeTypes())
        #expect(block == """
        - relates_to (symmetric): Two things that are connected in a way no other link describes
        - participates (person → event): A person takes part in an event
        - requires (task|event → any): A task or event needs something else to happen first
        - mentions (any → any): A note refers to a person, event or other node by name
        - part_of (any → any): A node is a piece of a larger node
        - follows_up (any → any): A node continues or follows up on an earlier node
        """)
    }

    @Test func customTypeAppearsWithItsDescriptionAndMatchedTypesComeFirst() async throws {
        let store = try await fixture()
        try await store.saveNodeType(NodeTypeDraft(name: "Recipe", typeDescription: "A recipe the user wants to keep"))
        let block = GraphPromptBlocks.nodeTypesBlock(try await store.nodeTypes(),
                                                     message: "Save this recipe for pancakes")
        #expect(block.hasPrefix("- recipe: A recipe the user wants to keep\n- note:"))
        #expect(block.contains("- recipe: A recipe the user wants to keep"))
    }

    @Test func disabledNodeTypeAndItsEdgesLeaveTheBlocks() async throws {
        let store = try await fixture()
        try await store.setNodeTypeEnabled(key: "person", enabled: false)
        let nodes = try await store.nodeTypes()
        let nodeBlock = GraphPromptBlocks.nodeTypesBlock(nodes)
        let edgeBlock = GraphPromptBlocks.edgeTypesBlock(try await store.edgeTypes(), nodeTypes: nodes)
        #expect(nodeBlock.contains("person") == false)
        #expect(edgeBlock.contains("participates") == false)
        #expect(edgeBlock.contains("relates_to") == true)
    }

    @Test func disabledEdgeTypeLeavesTheBlock() async throws {
        let store = try await fixture()
        try await store.setEdgeTypeEnabled(key: "mentions", enabled: false)
        let block = GraphPromptBlocks.edgeTypesBlock(try await store.edgeTypes(), nodeTypes: try await store.nodeTypes())
        #expect(block.contains("mentions") == false)
    }

    @Test func nodeBlockStopsAtTwelveTypes() async throws {
        let store = try await fixture()
        for index in 1...GraphDefaults.maxCustomNodeTypes {
            try await store.saveNodeType(NodeTypeDraft(name: "Kind \(index)", typeDescription: "Kind \(index)"))
        }
        let block = GraphPromptBlocks.nodeTypesBlock(try await store.nodeTypes())
        #expect(block.split(separator: "\n").count == GraphPromptBlocks.maxNodeTypes)
    }

    @Test func edgeBlockStopsAtTenTypes() async throws {
        let store = try await fixture()
        for index in 1...GraphDefaults.maxCustomEdgeTypes {
            try await store.saveEdgeType(EdgeTypeDraft(name: "Link \(index)", inverseName: "Linked \(index)",
                                                       typeDescription: "Link \(index)"))
        }
        let block = GraphPromptBlocks.edgeTypesBlock(try await store.edgeTypes(), nodeTypes: try await store.nodeTypes())
        #expect(block.split(separator: "\n").count == GraphPromptBlocks.maxEdgeTypes)
    }

    @Test func blockStaysInsideItsBudgetAndNeverCutsALine() async throws {
        let store = try await fixture()
        let long = String(repeating: "w", count: 80)
        for index in 1...GraphDefaults.maxCustomNodeTypes {
            try await store.saveNodeType(NodeTypeDraft(name: "Kind \(index)", typeDescription: long))
        }
        let block = GraphPromptBlocks.nodeTypesBlock(try await store.nodeTypes())
        #expect(block.count <= GraphPromptBlocks.typeBlockChars)
        #expect(block.contains("kind_1"))
        for line in block.split(separator: "\n") where line.contains("kind_") {
            #expect(line.hasSuffix(long))
        }
    }
}
