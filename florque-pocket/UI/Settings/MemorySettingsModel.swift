import Foundation
import Observation

// Purpose: state for Settings > Memory: the node and edge types, and the calls that change them. It holds value
// copies only; every rule (caps, locked flags, reassignment on delete) lives in `PocketStore`, so this model just
// forwards calls, reloads, and turns store errors into sentences.
//
// Testing: the rules are covered by `GraphStoreTests`. This file has no logic beyond the error wording.

@MainActor
@Observable
final class MemorySettingsModel {
    private let store: PocketStore
    private(set) var nodeTypes: [NodeTypeRecord] = []
    private(set) var edgeTypes: [EdgeTypeRecord] = []
    var errorMessage: String?

    init(store: PocketStore) {
        self.store = store
    }

    var customNodeCount: Int { nodeTypes.filter { !$0.isDefault }.count }
    var customEdgeCount: Int { edgeTypes.filter { !$0.isDefault }.count }
    var canAddNodeType: Bool { customNodeCount < GraphDefaults.maxCustomNodeTypes }
    var canAddEdgeType: Bool { customEdgeCount < GraphDefaults.maxCustomEdgeTypes }

    func load() async {
        do {
            nodeTypes = try await store.nodeTypes()
            edgeTypes = try await store.edgeTypes()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func setNodeType(_ key: String, enabled: Bool) async {
        await perform { try await store.setNodeTypeEnabled(key: key, enabled: enabled) }
    }

    func setEdgeType(_ key: String, enabled: Bool) async {
        await perform { try await store.setEdgeTypeEnabled(key: key, enabled: enabled) }
    }

    /// Returns true when the type was saved.
    func saveNodeType(_ draft: NodeTypeDraft) async -> Bool {
        await perform { try await store.saveNodeType(draft) } != nil
    }

    func saveEdgeType(_ draft: EdgeTypeDraft) async -> Bool {
        await perform { try await store.saveEdgeType(draft) } != nil
    }

    func deleteNodeType(_ key: String) async -> Bool {
        await perform { try await store.deleteNodeType(key: key) } != nil
    }

    func deleteEdgeType(_ key: String) async -> Bool {
        await perform { try await store.deleteEdgeType(key: key) } != nil
    }

    /// Runs one store call, reloads on success, and shows the error otherwise.
    @discardableResult
    private func perform<T>(_ work: () async throws -> T) async -> T? {
        do {
            let value = try await work()
            errorMessage = nil
            await load()
            return value
        } catch {
            errorMessage = Self.message(for: error)
            return nil
        }
    }

    static func message(for error: Error) -> String {
        switch error as? GraphStoreError {
        case .capReached(let kind, let limit)?:
            "You can have up to \(limit) custom \(kind)s. Delete one to add another."
        case .invalidName?:
            "Give the type a name and a description."
        case .keyTaken?:
            "A type with that name already exists."
        case .unknownNodeType?, .unknownEdgeType?:
            "That type no longer exists."
        case .unknownNode?:
            "That item no longer exists."
        case .defaultTypeNotDeletable(let key)?:
            "\(key.capitalized) is a default type and cannot be deleted. You can turn it off instead."
        case .descriptionTooLong(let limit)?:
            "Keep the description to \(limit) characters."
        case nil:
            "Something went wrong: \(error.localizedDescription)"
        }
    }
}
