import Foundation
import Testing
@testable import florque_pocket

// Purpose: the turn eval. Each labelled message from the corpus runs through `Assistant.handle` on a fresh store,
// and the result is scored on what was written (notes, tasks, due time) and on the classifier's intents.
//
// Testing approach:
// - oracleRepliesPassEveryMatrixCell: scripted replies per case. Proves the corpus labels and the pipeline agree,
//   with no model involved, so it runs on every test run.
// - intentKeepsStatementsAsNotesWhenTheClassifierFails: a negative check that a failing classifier does not lose a note.
// - liveMatrix (only with POCKET_EVAL=1): the real on-device or cloud model runs the corpus, and the report
//   shows pass rate and intent accuracy.

/// Eval matrix: every workflow × prompt set over one labelled corpus.
///
/// Expected writes for each message (the spec):
/// - statement, event, fact, idea: one Note, no Task;
/// - action: one Task (due when a day and a time were given), no Note;
/// - statement that also asks for an action: one Note and one Task;
/// - question, greeting: no writes;
/// - unclear: no writes, one question back.
///
/// Runners:
/// - self-test: each matrix cell replays its oracle replies, which checks the harness and the workflow wiring;
/// - negative test: a model that turns every message into a Task;
/// - live run (`TEST_RUNNER_POCKET_EVAL=1`, backend from `TEST_RUNNER_POCKET_EVAL_BACKEND`, `apple` or `firebase`):
///   the real model on the device, printing one table per matrix cell.

nonisolated struct EvalCase: Sendable {
    enum Expect: String, Sendable, CaseIterable {
        case statement, task, mixed, clarify, question, greeting
    }
    let id: String
    let text: String
    let expect: Expect
    /// Notes and Tasks a correct turn leaves in the store.
    let notes: Int
    let tasks: Int
    /// Expected due time as a prefix of the stored value, e.g. "2026-11-27T09:00".
    let due: String?
    /// Replies the `intent` workflow receives: the classifier first, then the step's reply.
    let intentReplies: [String]

    /// The intents a correct classifier returns.
    var intents: Set<Intent> {
        switch expect {
        case .statement: [.note]
        case .task: [.task]
        case .mixed: [.note, .task]
        case .clarify: [.unclear]
        case .question, .greeting: [.discuss]
        }
    }
}

nonisolated struct EvalResult: Sendable {
    let id: String
    let expect: EvalCase.Expect
    let passed: Bool
    let notes: Int
    let tasks: Int
    let due: String?
    let intents: [Intent]
    /// Nil for workflows without a classifier.
    let intentCorrect: Bool?
    let route: String
    let say: String
    let failure: String?
}

nonisolated enum TurnEval {
    /// Monday 2026-11-23 08:00 UTC. "Friday" is 2026-11-27, "tomorrow" 2026-11-24, "Monday" 2026-11-30.
    static let now = Date(timeIntervalSince1970: 1_795_420_800)
    static let zone = TimeZone(identifier: "UTC")!

    /// Every (workflow, prompt set) cell the matrix runs.
    static let matrix: [(WorkflowID, PromptSet)] = [(.intent, .intentV1)]

    private static let answer = #"{"calls":[],"say":"Let me check."}"#
    private static func task(_ title: String, due: String? = nil) -> String {
        let dueField = due.map { #","due":"\#($0)""# } ?? ""
        return #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"\#(title)"\#(dueField)}}],"say":"Added."}"#
    }

    static let corpus: [EvalCase] = [
        // Statements, events and facts: Note only.
        EvalCase(id: "S1", text: "Pricing page should come before the checkout test.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),
        EvalCase(id: "S2", text: "I have a meeting with Anna on Monday.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),
        EvalCase(id: "S3", text: "The launch got moved to December.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),
        EvalCase(id: "S4", text: "Met Ben at the conference, he works on payments.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),
        EvalCase(id: "S5", text: "Idea: a weekly digest email could replace the newsletter.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),
        EvalCase(id: "S6", text: "Concert tickets are for Saturday at 8pm.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),
        EvalCase(id: "S7", text: "Dentist appointment Thursday at 10.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),
        EvalCase(id: "S8", text: "The landlord said the boiler is fixed.", expect: .statement, notes: 1, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["note"]}"#]),

        // Actions: one Task, no Note.
        EvalCase(id: "T1", text: "Remind me to call the landlord Friday at 9am.", expect: .task, notes: 0, tasks: 1, due: "2026-11-27T09:00",
                 intentReplies: [#"{"intents":["task"]}"#, task("Call the landlord", due: "2026-11-27T09:00:00")]),
        EvalCase(id: "T2", text: "Book the dentist for tomorrow at 3pm.", expect: .task, notes: 0, tasks: 1, due: "2026-11-24T15:00",
                 intentReplies: [#"{"intents":["task"]}"#, task("Book the dentist", due: "2026-11-24T15:00:00")]),
        EvalCase(id: "T3", text: "Send the deck to Maria by Wednesday 5pm.", expect: .task, notes: 0, tasks: 1, due: "2026-11-25T17:00",
                 intentReplies: [#"{"intents":["task"]}"#, task("Send the deck to Maria", due: "2026-11-25T17:00:00")]),
        EvalCase(id: "T4", text: "Buy milk.", expect: .task, notes: 0, tasks: 1, due: nil,
                 intentReplies: [#"{"intents":["task"]}"#, task("Buy milk")]),
        EvalCase(id: "T5", text: "Pay the electricity bill this week.", expect: .task, notes: 0, tasks: 1, due: nil,
                 intentReplies: [#"{"intents":["task"]}"#, task("Pay the electricity bill")]),
        EvalCase(id: "T6", text: "Need to email the accountant about the VAT form.", expect: .task, notes: 0, tasks: 1, due: nil,
                 intentReplies: [#"{"intents":["task"]}"#, task("Email the accountant about the VAT form")]),

        // Statement plus action: one Note and one Task.
        EvalCase(id: "M1", text: "The checkout test is blocked by the pricing page. Remind me to fix the pricing page Monday at 10am.",
                 expect: .mixed, notes: 1, tasks: 1, due: "2026-11-30T10:00",
                 intentReplies: [#"{"intents":["note","task"]}"#, task("Fix the pricing page", due: "2026-11-30T10:00:00")]),

        // Unclear: no writes, one question.
        EvalCase(id: "C1", text: "Remind me to call the landlord Friday morning.", expect: .clarify, notes: 0, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["unclear"]}"#, #"{"calls":[],"say":"Which time on Friday?"}"#]),

        // Questions and greetings: no writes.
        EvalCase(id: "Q1", text: "What do I need to do about the landlord?", expect: .question, notes: 0, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["discuss"]}"#, answer]),
        EvalCase(id: "Q2", text: "What did I note about pricing?", expect: .question, notes: 0, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["discuss"]}"#, answer]),
        EvalCase(id: "Q3", text: "What's due this week?", expect: .question, notes: 0, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["discuss"]}"#, answer]),
        EvalCase(id: "G1", text: "Hi there.", expect: .greeting, notes: 0, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["discuss"]}"#, #"{"calls":[],"say":"Hi. What's on your mind?"}"#]),
        EvalCase(id: "G2", text: "Thanks!", expect: .greeting, notes: 0, tasks: 0, due: nil,
                 intentReplies: [#"{"intents":["discuss"]}"#, #"{"calls":[],"say":"You're welcome."}"#]),
    ]

    /// Runs every case through `Assistant.handle` on a fresh store and scores what was written.
    static func run(_ cases: [EvalCase], workflow: WorkflowID, prompts: PromptSet, policy: RoutePolicy,
                    model: (EvalCase) async -> any ModelAdapter) async throws -> [EvalResult] {
        var results: [EvalResult] = []
        for c in cases {
            let store = try makeMemoryStore()
            let assistant = Assistant(store: store, model: await model(c), clock: { now },
                                      timeZone: zone, workflow: workflow, prompts: prompts)
            let turn = try await assistant.handle(c.text, policy: policy)
            let noteCount = try await store.recentNotes(limit: 1000).count
            let tasks = try await store.openTasks()
            let due = tasks.compactMap(\.due).first.map { DateParsing.formatLocal($0, in: zone) }

            var problems: [String] = []
            if noteCount != c.notes { problems.append("notes \(noteCount), expected \(c.notes)") }
            if tasks.count != c.tasks { problems.append("tasks \(tasks.count), expected \(c.tasks)") }
            if let want = c.due, !(due ?? "").hasPrefix(want) { problems.append("due \(due ?? "none"), expected \(want)") }
            let intentCorrect: Bool? = workflow == .intent ? Set(turn.intents) == c.intents : nil
            results.append(EvalResult(id: c.id, expect: c.expect, passed: problems.isEmpty, notes: noteCount,
                                      tasks: tasks.count, due: due, intents: turn.intents, intentCorrect: intentCorrect,
                                      route: turn.routeLabel, say: turn.say,
                                      failure: problems.isEmpty ? nil : problems.joined(separator: "; ")))
        }
        return results
    }

    /// Per-class results for one matrix cell.
    static func report(_ results: [EvalResult], title: String) -> String {
        var lines = ["== \(title)", "id   class      result  notes tasks due              intents       route"]
        for r in results {
            let mark = r.passed ? "PASS" : "FAIL"
            let intents = r.intents.isEmpty ? "-" : r.intents.map(\.rawValue).joined(separator: ",")
            lines.append("\(pad(r.id, 4)) \(pad(r.expect.rawValue, 10)) \(mark)    \(r.notes)     \(r.tasks)     \(pad(r.due ?? "-", 16)) \(pad(intents, 13)) \(r.route)")
            if let f = r.failure { lines.append("     -> \(f) | say: \(r.say)") }
        }
        for cls in EvalCase.Expect.allCases {
            let rs = results.filter { $0.expect == cls }
            if rs.isEmpty { continue }
            lines.append("\(cls.rawValue): \(rs.filter { $0.passed }.count)/\(rs.count)")
        }
        let classified = results.compactMap(\.intentCorrect)
        if !classified.isEmpty {
            lines.append("intent accuracy: \(classified.filter { $0 }.count)/\(classified.count)")
        }
        lines.append("total: \(results.filter { $0.passed }.count)/\(results.count)")
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}

/// Returns queued replies in order and repeats the last one when the queue runs out.
@MainActor
class ReplayModel: ModelAdapter {
    private var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func generate(system: String, user: String, policy: RoutePolicy) async throws -> ModelReply {
        let text = replies.count > 1 ? replies.removeFirst() : (replies.first ?? "")
        return ModelReply(text: text, route: .onDevice, modelName: "replay", seconds: 0)
    }
}

private let liveEnabled = ProcessInfo.processInfo.environment["POCKET_EVAL"] == "1"

@Suite struct TurnEvalTests {
    @Test func oracleRepliesPassEveryMatrixCell() async throws {
        for (workflow, prompts) in TurnEval.matrix {
            let results = try await TurnEval.run(TurnEval.corpus, workflow: workflow, prompts: prompts, policy: .forceOnDevice) { c in
                await ReplayModel(c.intentReplies)
            }
            print(TurnEval.report(results, title: "\(workflow.rawValue) / \(prompts.name) (oracle)"))
            #expect(results.allSatisfy { $0.passed }, "oracle replies must pass every case for \(workflow.rawValue) / \(prompts.name)")
        }
    }

    @Test func intentKeepsStatementsAsNotesWhenTheClassifierFails() async throws {
        // A model that turns every message into a Task: the classifier never parses, so the message is kept as a note and no Task is created.
        let taskForEverything = #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Something"}}],"say":"Added."}"#
        let results = try await TurnEval.run(TurnEval.corpus, workflow: .intent, prompts: .intentV1, policy: .forceOnDevice) { _ in
            await ReplayModel([taskForEverything])
        }
        let statements = results.filter { $0.expect == .statement }
        #expect(statements.allSatisfy { $0.passed }, "intent: statements stay notes and create no task")
        #expect(results.filter { $0.expect == .task }.allSatisfy { !$0.passed }, "intent: without a classification, tasks are not created")
    }

    @Test(.enabled(if: liveEnabled)) func liveMatrix() async throws {
        let backend = ProcessInfo.processInfo.environment["POCKET_EVAL_BACKEND"] ?? "apple"
        for (workflow, prompts) in TurnEval.matrix {
            let results = try await TurnEval.run(TurnEval.corpus, workflow: workflow, prompts: prompts, policy: .forceOnDevice) { _ in
                backend == "firebase" ? FirebaseModelAdapter() as any ModelAdapter : FoundationModelsAdapter() as any ModelAdapter
            }
            print("LIVE EVAL backend=\(backend)")
            print(TurnEval.report(results, title: "\(workflow.rawValue) / \(prompts.name)"))
        }
    }
}
