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
}

@MainActor
@Observable
final class ChatViewModel {
    private(set) var entries: [ChatEntry] = []
    var policy: RoutePolicy = .auto

    /// One orchestrator per backend; both share the same store. The backend picker chooses one.
    enum Backend: String, CaseIterable, Sendable {
        case apple
        case firebase
    }

    var backend: Backend = .apple
    private let assistants: [Backend: Assistant]
    private let reminders: any RemindersAdapter
    private let me = User(id: "me", name: "You", avatarURL: nil, isCurrentUser: true)
    private let pocket = User(id: "pocket", name: "Pocket", avatarURL: nil, isCurrentUser: false)

    init(assistants: [Backend: Assistant], reminders: any RemindersAdapter) {
        self.assistants = assistants
        self.reminders = reminders
    }

    private var assistant: Assistant {
        assistants[backend] ?? assistants[.apple]!
    }

    /// Builds the production graph: file-backed SwiftData, Firebase model, EventKit reminders.
    static func makeDefault() -> ChatViewModel {
        guard let url = Bundle.main.url(forResource: "pocket.linkml", withExtension: "yaml"),
              let yaml = try? String(contentsOf: url, encoding: .utf8),
              let ontology = try? Ontology.load(yaml: yaml) else {
            fatalError("pocket.linkml.yaml is missing from the app bundle")
        }
        let store = Self.openStore()
        let assistants: [Backend: Assistant] = [
            .apple: Assistant(ontology: ontology, store: store, model: FoundationModelsAdapter()),
            .firebase: Assistant(ontology: ontology, store: store, model: FirebaseModelAdapter()),
        ]
        return ChatViewModel(assistants: assistants, reminders: EventKitReminders())
    }

    /// Application Support file store; falls back to memory so the app still opens.
    private static func openStore() -> any GraphStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let store = try? SwiftDataGraphStore(url: dir.appendingPathComponent("pocket.store")) {
            return store
        }
        return InMemoryGraphStore()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(ChatEntry(id: UUID().uuidString, isUser: true, text: trimmed))
        let placeholder = ChatEntry(id: UUID().uuidString, isUser: false, text: "…")
        entries.append(placeholder)
        let policy = self.policy
        Task {
            do {
                let turn = try await assistant.handle(trimmed, policy: policy)
                replace(placeholder.id, with: ChatEntry(id: placeholder.id, isUser: false, text: turn.say,
                                                        routeLabel: turn.routeLabel, proposals: turn.proposals))
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
