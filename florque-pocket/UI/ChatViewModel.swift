import Foundation
import Observation
import ExyteChat

/// One chat line. Assistant lines carry the route badge and the tasks waiting for Accept or Dismiss.
struct ChatEntry: Identifiable, Equatable {
    let id: String
    let isUser: Bool
    var text: String
    var routeLabel: String = ""
    var proposals: [TaskProposal] = []
    /// What this reply wrote to the graph. Set only on replies that wrote something; Undo reverses it.
    var changeset: GraphChangeset? = nil
}

@MainActor
@Observable
final class ChatViewModel {
    private(set) var entries: [ChatEntry] = []
    var policy: RoutePolicy = .auto

    /// The model backend the assistant runs on. Fixed for the view model's lifetime.
    enum Backend: String, CaseIterable, Sendable {
        case apple
        case firebase
    }

    /// The one assistant this chat talks to: a backend and a workflow, chosen when the view model is built.
    private let assistant: Assistant
    private let reminders: any RemindersAdapter
    /// The same store the assistant writes to, for the Settings screen's memory types.
    let memoryStore: PocketStore
    private let me = User(id: "me", name: "You", avatarURL: nil, isCurrentUser: true)
    private let pocket = User(id: "pocket", name: "Pocket", avatarURL: nil, isCurrentUser: false)

    init(assistant: Assistant, reminders: any RemindersAdapter, memoryStore: PocketStore) {
        self.assistant = assistant
        self.reminders = reminders
        self.memoryStore = memoryStore
    }

    /// Builds the chat's assistant from a backend and a workflow. The store and EventKit reminders are the app's own.
    static func makeDefault(backend: Backend, workflow: WorkflowID) -> ChatViewModel {
        let model: any ModelAdapter = switch backend {
        case .apple: FoundationModelsAdapter()
        case .firebase: FirebaseModelAdapter()
        }
        let reminders = EventKitReminders()
        let store = Self.openStore()
        // Default node and edge types exist before anything reads them; the old notes and tasks are copied once.
        Task {
            try? await store.seedGraphDefaults()
            _ = try? await store.importLegacyIfNeeded()
        }
        let assistant = Assistant(store: store, model: model, workflow: workflow, reminders: reminders)
        return ChatViewModel(assistant: assistant, reminders: reminders, memoryStore: store)
    }

    /// Application Support file store; falls back to memory so the app still opens (nothing persists then).
    private static func openStore() -> PocketStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let container = try? PocketStore.fileContainer(url: dir.appendingPathComponent("pocket.store")) {
            return PocketStore(modelContainer: container)
        }
        guard let container = try? PocketStore.memoryContainer() else {
            fatalError("SwiftData could not open even an in-memory store")
        }
        return PocketStore(modelContainer: container)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The last five chat lines (user and assistant) before this message, as the workflows expect them.
        let history = entries.suffix(5).filter { $0.text != "…" }.map { "\($0.isUser ? "user" : "assistant"): \($0.text)" }
        entries.append(ChatEntry(id: UUID().uuidString, isUser: true, text: trimmed))
        let placeholder = ChatEntry(id: UUID().uuidString, isUser: false, text: "…")
        entries.append(placeholder)
        let policy = self.policy
        let target = assistant
        Task {
            do {
                let turn = try await target.handle(trimmed, policy: policy, history: history)
                replace(placeholder.id, with: ChatEntry(id: placeholder.id, isUser: false, text: turn.say,
                                                        routeLabel: turn.routeLabel, proposals: turn.proposals,
                                                        changeset: turn.changeset))
            } catch {
                replace(placeholder.id, with: ChatEntry(id: placeholder.id, isUser: false,
                                                        text: "Something went wrong: \(error.localizedDescription)"))
            }
        }
    }

    func accept(_ proposal: TaskProposal, in entryId: String) {
        Task {
            do {
                try await assistant.accept(taskId: proposal.id, reminders: reminders)
                removeProposal(proposal.id, from: entryId)
                entries.append(ChatEntry(id: UUID().uuidString, isUser: false, text: "Accepted: \(proposal.title)"))
            } catch {
                entries.append(ChatEntry(id: UUID().uuidString, isUser: false, text: "Couldn't accept: \(error.localizedDescription)"))
            }
        }
    }

    /// Reverses the graph writes of one reply, and removes the reminders it made.
    func undo(_ entryId: String) {
        guard let i = entries.firstIndex(where: { $0.id == entryId }), let changeset = entries[i].changeset else { return }
        entries[i].changeset = nil
        let reminders = reminders
        let target = assistant
        Task {
            do {
                try await target.undo(changeset, reminders: reminders)
                entries.append(ChatEntry(id: UUID().uuidString, isUser: false, text: "Undone."))
            } catch {
                entries.append(ChatEntry(id: UUID().uuidString, isUser: false, text: "Couldn't undo: \(error.localizedDescription)"))
            }
        }
    }

    func dismiss(_ proposal: TaskProposal, in entryId: String) {
        Task {
            try? await assistant.dismiss(taskId: proposal.id)
            removeProposal(proposal.id, from: entryId)
        }
    }

    // MARK: exyte mapping

    var messages: [Message] {
        entries.map { e in
            var text = e.text
            if !e.routeLabel.isEmpty { text += "\n\(e.routeLabel)" }
            return Message(id: e.id, user: e.isUser ? me : pocket, createdAt: Date(), text: text,
                           customData: ["entryId": e.id])
        }
    }

    // MARK: helpers

    private func replace(_ id: String, with entry: ChatEntry) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i] = entry }
    }

    private func removeProposal(_ taskId: String, from entryId: String) {
        guard let i = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[i].proposals.removeAll { $0.id == taskId }
    }
}
