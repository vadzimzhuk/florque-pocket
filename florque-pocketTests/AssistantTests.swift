import Foundation
import Testing
@testable import florque_pocket

/// Scripted model: returns the queued replies in order and records each call.
actor FakeModel: ModelAdapter {
    private var queue: [(String, Route)]
    private(set) var calls: [(user: String, policy: RoutePolicy)] = []

    init(_ replies: [(String, Route)]) { queue = replies }

    func generate(system: String, user: String, policy: RoutePolicy) async throws -> ModelReply {
        calls.append((user, policy))
        guard !queue.isEmpty else { throw URLError(.cannotConnectToHost) }
        let (text, route) = queue.removeFirst()
        return ModelReply(text: text, route: route, modelName: "fake", seconds: 0.5)
    }
}

actor FakeReminders: RemindersAdapter {
    private(set) var created: [(String, Date)] = []
    func createReminder(title: String, due: Date) async throws -> String {
        created.append((title, due))
        return "ek-\(created.count)"
    }
}

private func ontology() throws -> Ontology {
    let url = try #require(Bundle.main.url(forResource: "pocket.linkml", withExtension: "yaml"))
    return try Ontology.load(yaml: String(contentsOf: url, encoding: .utf8))
}

private let fixedNow = Date(timeIntervalSince1970: 1_795_000_000)
private let validTask = #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Call landlord","due":"2026-11-27T09:00:00"}}],"say":"Added a task."}"#

@Suite struct AssistantTests {
    private func make(_ model: FakeModel, store: InMemoryGraphStore) throws -> Assistant {
        Assistant(ontology: try ontology(), store: store, model: model, clock: { fixedNow }, timeZone: TimeZone(identifier: "UTC")!)
    }

    @Test func capturesNoteAndProposesTask() async throws {
        let store = InMemoryGraphStore()
        let model = FakeModel([(validTask, .onDevice)])
        let turn = try await make(model, store: store).handle("remind me to call the landlord Friday 9am", policy: .auto)

        let snap = try await store.read()
        #expect(snap.nodes[turn.noteId]?.className == "Note")
        #expect(snap.nodes[turn.noteId]?.props["body"]?.stringValue?.contains("landlord") == true)
        #expect(turn.proposalIds.count == 1)
        #expect(turn.proposals.first?.title == "Call landlord")
        #expect(snap.nodes[turn.proposalIds[0]]?.status == "proposed")
        #expect(turn.say == "Added a task.")
        #expect(turn.savedOnly == false)
        #expect(turn.routeLabel.hasPrefix("On-device"))
    }

    @Test func repairsRejectedReplyOnce() async throws {
        let store = InMemoryGraphStore()
        let bad = #"{"calls":[{"tool":"remember","args":{"type":"Note","title":"x","kind":"rumour"}}],"say":""}"#
        let model = FakeModel([(bad, .onDevice), (validTask, .onDevice)])
        let turn = try await make(model, store: store).handle("call the landlord", policy: .auto)
        #expect(await model.calls.count == 2)
        #expect(turn.proposalIds.count == 1)
    }

    @Test func escalatesToCloudAfterOnDeviceFailures() async throws {
        let store = InMemoryGraphStore()
        let bad = #"{"calls":[{"tool":"remember","args":{"type":"Nope"}}],"say":""}"#
        let model = FakeModel([(bad, .onDevice), (bad, .onDevice), (validTask, .cloud)])
        let turn = try await make(model, store: store).handle("call the landlord", policy: .auto)
        let calls = await model.calls
        #expect(calls.count == 3)
        #expect(calls[2].policy == .forceCloud)
        #expect(turn.routeLabel.hasPrefix("Cloud"))
        #expect(turn.proposalIds.count == 1)
    }

    @Test func todoWithNoProposalNeverClaimsATask() async throws {
        let store = InMemoryGraphStore()
        let silent = #"{"calls":[],"say":"I've reminded you to call the landlord."}"#
        let model = FakeModel([(silent, .cloud), (silent, .cloud)])
        let turn = try await make(model, store: store).handle("Remind me to call the landlord Friday at 9am", policy: .forceCloud)
        #expect(turn.savedOnly)
        #expect(turn.proposalIds.isEmpty)
        #expect(!turn.say.contains("reminded"))
    }

    @Test func silentOnDeviceReplyForTodoEscalates() async throws {
        let store = InMemoryGraphStore()
        let silent = #"{"calls":[],"say":"You will be reminded."}"#
        let model = FakeModel([(silent, .onDevice), (validTask, .cloud)])
        let turn = try await make(model, store: store).handle("Remind me to call the landlord Friday at 9am", policy: .auto)
        #expect(await model.calls.count == 2)
        #expect(turn.proposalIds.count == 1)
    }

    @Test func noEscalationWhenPolicyIsOnDeviceOnly() async throws {
        let store = InMemoryGraphStore()
        let bad = #"{"calls":[{"tool":"remember","args":{"type":"Nope"}}],"say":""}"#
        let model = FakeModel([(bad, .onDevice), (bad, .onDevice)])
        _ = try await make(model, store: store).handle("call the landlord", policy: .forceOnDevice)
        #expect(await model.calls.count == 2)
    }

    @Test func keepsNoteWhenModelFails() async throws {
        let store = InMemoryGraphStore()
        let model = FakeModel([])
        let turn = try await make(model, store: store).handle("Pricing page before checkout test", policy: .auto)
        #expect(turn.savedOnly == true)
        #expect(try await store.read().nodes[turn.noteId] != nil)
    }

    @Test func readAnswerTakesASecondTurn() async throws {
        let store = InMemoryGraphStore()
        let assistant = try make(FakeModel([(validTask, .onDevice)]), store: store)
        _ = try await assistant.handle("call the landlord", policy: .auto)

        let recall = #"{"calls":[{"tool":"recall","args":{"text":"landlord"}}],"say":""}"#
        let answer = #"{"calls":[],"say":"You have one task: call the landlord."}"#
        let model = FakeModel([(recall, .onDevice), (answer, .onDevice)])
        let second = try make(model, store: store)
        let turn = try await second.handle("what do I need to do about the landlord?", policy: .auto)
        #expect(await model.calls.count == 2)
        #expect(turn.say == "You have one task: call the landlord.")
    }

    @Test func acceptActivatesAndSchedulesReminder() async throws {
        let store = InMemoryGraphStore()
        let assistant = try make(FakeModel([(validTask, .onDevice)]), store: store)
        let turn = try await assistant.handle("call the landlord", policy: .auto)
        let reminders = FakeReminders()
        try await assistant.accept(taskId: turn.proposalIds[0], reminders: reminders)

        let node = try #require(try await store.read().nodes[turn.proposalIds[0]])
        #expect(node.status == "active")
        #expect(node.props["event_id"] == .string("ek-1"))
        #expect(await reminders.created.count == 1)
    }

    @Test func dismissDropsTask() async throws {
        let store = InMemoryGraphStore()
        let assistant = try make(FakeModel([(validTask, .onDevice)]), store: store)
        let turn = try await assistant.handle("call the landlord", policy: .auto)
        try await assistant.dismiss(taskId: turn.proposalIds[0])
        #expect(try await store.read().nodes[turn.proposalIds[0]]?.status == "dropped")
    }

    @Test func digestListsOpenTasksAndNotes() throws {
        let snap = GraphSnapshot()
        var s = snap
        s.nodes["t1"] = DynamicNode(id: "t1", className: "Task", props: ["title": .string("Call"), "status": .string("active")])
        s.nodes["n1"] = DynamicNode(id: "n1", className: "Note", props: ["title": .string("Idea"), "status": .string("active")])
        let text = Digest.build(s)
        #expect(text.contains("Task t1 | Call"))
        #expect(text.contains("Note n1 | Idea"))
    }
}

