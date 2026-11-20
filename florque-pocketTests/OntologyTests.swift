import Foundation
import Testing
@testable import florque_pocket

private func pocketOntology() throws -> Ontology {
    let url = try #require(Bundle.main.url(forResource: "pocket.linkml", withExtension: "yaml"))
    return try Ontology.load(yaml: String(contentsOf: url, encoding: .utf8))
}

private let now = Date(timeIntervalSince1970: 1_795_000_000)

@Suite struct OntologyLoadingTests {
    @Test func loadsConcreteTypesAndInheritance() throws {
        let ont = try pocketOntology()
        #expect(ont.concreteClassNames == ["Note", "Task", "Topic"])
        #expect(ont.isA("Task", "Node"))
        #expect(!ont.isA("Note", "Task"))
        #expect(ont.classDef("Task")?.slots["title"]?.required == true)
    }

    @Test func readsEnumsAndEdges() throws {
        let ont = try pocketOntology()
        #expect(ont.enums["Status"]?.values.contains("proposed") == true)
        let note = try #require(ont.classDef("Note"))
        #expect(note.edgeSlots.map(\.name).sorted() == ["mentions", "relates_to"])
        #expect(note.slots["kind"]?.required == true)
    }

    @Test func rejectsUnknownParent() {
        let yaml = """
        classes:
          A:
            is_a: Missing
            slots: []
        """
        #expect(throws: OntologyError.self) { try Ontology.load(yaml: yaml) }
    }

    @Test func schemaChangeNeedsOnlyYAML() throws {
        let original = try String(contentsOf: #require(Bundle.main.url(forResource: "pocket.linkml", withExtension: "yaml")), encoding: .utf8)
        // Add a field in YAML only: the validator and the prompt pick it up without code changes.
        let edited = original
            .replacingOccurrences(of: "slots:\n  id:", with: "slots:\n  priority:\n    range: integer\n  id:")
            .replacingOccurrences(of: "slots: [due, event_id, about, depends_on]",
                                  with: "slots: [due, event_id, about, depends_on, priority]")
        let ont = try Ontology.load(yaml: edited)
        let check = Validator.checkNode(ont, className: "Task", props: ["title": .string("x"), "priority": .number(2)], partial: false)
        #expect(check.issues.isEmpty)
        #expect(PromptCompiler.ontologyGuide(ont).contains("priority: integer"))
    }
}

@Suite struct ValidationTests {
    @Test func enumIsMatchedLeniently() throws {
        let ont = try pocketOntology()
        let check = Validator.checkNode(ont, className: "Note",
                                        props: ["title": .string("t"), "kind": .string("Thought")], partial: false)
        #expect(check.issues.isEmpty)
        #expect(check.props["kind"] == .string("thought"))
    }

    @Test func reportsMissingRequiredAndBadValues() throws {
        let ont = try pocketOntology()
        let check = Validator.checkNode(ont, className: "Task",
                                        props: ["due": .string("tomorrow morning"), "colour": .string("red")], partial: false)
        #expect(check.issues.contains { $0.contains("requires title") })
        #expect(check.issues.contains { $0.hasPrefix("due:") })
        #expect(check.issues.contains { $0.contains("colour") })
    }

    @Test func rejectsEdgeAsField() throws {
        let ont = try pocketOntology()
        let check = Validator.checkNode(ont, className: "Note", props: ["mentions": .string("x")], partial: true)
        #expect(check.issues.count == 1)
    }
}

@Suite struct ToolExecutorTests {
    private func executor() throws -> (ToolExecutor, InMemoryGraphStore) {
        let store = InMemoryGraphStore()
        return (ToolExecutor(ontology: try pocketOntology(), store: store), store)
    }

    @Test func capturesNoteWithTopicAndLink() async throws {
        let (exec, store) = try executor()
        let reply = """
        {"calls":[
          {"tool":"remember","args":{"type":"Topic","id":"pricing","title":"Pricing"}},
          {"tool":"remember","args":{"type":"Note","title":"Pricing page first","body":"pricing page before checkout test","kind":"thought","mentions":["pricing"]}}
        ],"say":"Noted."}
        """
        let outcome = await exec.run(reply: reply, now: now)
        #expect(outcome.committed)
        #expect(outcome.issues.isEmpty)
        let snap = try await store.read()
        #expect(snap.nodes.count == 2)
        #expect(snap.edges.count == 1)
        let note = try #require(snap.nodes.values.first { $0.className == "Note" })
        #expect(note.status == "proposed")
        #expect(note.props["kind"] == .string("thought"))
    }

    @Test func rejectedBatchWritesNothing() async throws {
        let (exec, store) = try executor()
        let reply = """
        {"calls":[
          {"tool":"remember","args":{"type":"Topic","id":"ok","title":"Fine"}},
          {"tool":"remember","args":{"type":"Note","title":"bad","kind":"rumour"}}
        ],"say":""}
        """
        let outcome = await exec.run(reply: reply, now: now)
        #expect(!outcome.committed)
        #expect(outcome.issues.count == 1)
        #expect(try await store.read().nodes.isEmpty)
    }

    @Test func linkTargetsAreChecked() async throws {
        let (exec, store) = try executor()
        _ = await exec.run(reply: #"{"calls":[{"tool":"remember","args":{"type":"Note","id":"n1","title":"a","kind":"note"}},{"tool":"remember","args":{"type":"Note","id":"n2","title":"b","kind":"note"}}]}"#, now: now)
        // A note may not be mentioned as a topic.
        let bad = await exec.run(reply: #"{"calls":[{"tool":"link","args":{"from":"n1","link":"mentions","to":"n2"}}]}"#, now: now)
        #expect(!bad.committed)
        #expect(bad.issues.first?.contains("must point at Topic") == true)
        #expect(try await store.read().edges.isEmpty)
    }

    @Test func updateReplacesLinksAndKeepsOtherFields() async throws {
        let (exec, store) = try executor()
        _ = await exec.run(reply: #"{"calls":[{"tool":"remember","args":{"type":"Topic","id":"t1","title":"A"}},{"tool":"remember","args":{"type":"Topic","id":"t2","title":"B"}},{"tool":"remember","args":{"type":"Note","id":"n","title":"keep me","kind":"note","mentions":["t1"]}}]}"#, now: now)
        let out = await exec.run(reply: #"{"calls":[{"tool":"remember","args":{"type":"Note","id":"n","mentions":["t2"]}}]}"#, now: now)
        #expect(out.committed)
        let snap = try await store.read()
        #expect(snap.edges == [DynamicEdge(from: "n", slot: "mentions", to: "t2")])
        #expect(snap.nodes["n"]?.title == "keep me")
    }

    @Test func tooManyCallsIsRejected() async throws {
        let (exec, _) = try executor()
        let call = #"{"tool":"recall","args":{}}"#
        let reply = #"{"calls":["# + Array(repeating: call, count: 6).joined(separator: ",") + #"]}"#
        let out = await exec.run(reply: reply, now: now)
        #expect(out.issues.first?.contains("too many calls") == true)
    }

    @Test func recallAndDueReadTheGraph() async throws {
        let (exec, _) = try executor()
        _ = await exec.run(reply: #"{"calls":[{"tool":"remember","args":{"type":"Task","id":"call","title":"Call landlord","due":"2026-11-27T09:00:00"}},{"tool":"remember","args":{"type":"Note","id":"p","title":"Pricing","body":"pricing page first","kind":"note"}}]}"#, now: now)
        let recall = await exec.run(reply: #"{"calls":[{"tool":"recall","args":{"text":"pricing"}}]}"#, now: now)
        #expect(recall.results.count == 1)
        let due = await exec.run(reply: #"{"calls":[{"tool":"due","args":{"before":"2026-12-01T00:00:00"}}]}"#, now: now)
        #expect(due.results.count == 1)
        #expect(due.results.first?.objectValue?["id"] == .string("call"))
    }

    @Test func replyWrappedInProseStillParses() async throws {
        let (exec, _) = try executor()
        let out = await exec.run(reply: "Sure:\n```json\n{\"calls\":[],\"say\":\"Hi\"}\n```", now: now)
        #expect(out.committed)
        #expect(out.say == "Hi")
    }
}
