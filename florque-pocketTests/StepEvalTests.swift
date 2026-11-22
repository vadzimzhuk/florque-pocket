import Foundation
import Testing
@testable import florque_pocket

/// Step evals: every prompt step of the intent workflow is exercised on its own, through `Assistant.handle`.
/// A call is attributed to a step by its system prompt, so a case checks that the step ran and did its job.
/// Every reply is also checked against its step's data-structure contract (`ReplyFormat`).
///
/// Two kinds of case:
/// - scripted (`live == false`): the replies are fixed, so the case proves the step's wiring and its checks;
/// - live (`live == true`): the real model runs the corpus message, so the case measures the step's quality.
///
/// Running the live part:
/// - Xcode: add `POCKET_EVAL=1` to the test scheme's environment variables (and `POCKET_EVAL_BACKEND=apple` or `firebase`);
/// - command line: `TEST_RUNNER_POCKET_EVAL=1 TEST_RUNNER_POCKET_EVAL_BACKEND=apple xcodebuild test ...`.
/// The live test prints one table per matrix cell, and fails when any reply breaks its contract.

nonisolated struct StepCall: Sendable {
    /// The step whose system prompt the call used. Nil when the prompt matches no step.
    let role: PromptRole?
    let policy: RoutePolicy
    /// The model's reply, as received.
    let reply: String
}

/// What a turn did, as seen by one step's check.
nonisolated struct StepRun: Sendable {
    let calls: [StepCall]
    let notes: Int
    let tasks: Int
    let due: String?
    let intents: [Intent]
    let say: String

    var roles: [PromptRole] { calls.compactMap(\.role) }
}

nonisolated struct StepCase: Sendable {
    let id: String
    let workflow: WorkflowID
    /// The step the case is about. Its check also requires that this step ran.
    let step: PromptRole
    let text: String
    let policy: RoutePolicy
    /// Tasks already in the store before the turn, for read answers. Not counted as writes.
    let seed: [NewTask]
    /// Scripted replies in call order. The last one repeats when the script runs out.
    let replies: [String]
    let live: Bool
    /// Nil when the step behaved, otherwise what was wrong.
    let check: @Sendable (StepRun) -> String?
}

/// One reply's contract check. `problem` is nil when the reply conforms.
nonisolated struct FormatCheck: Sendable {
    let role: PromptRole?
    let problem: String?
    let reply: String
}

nonisolated struct StepResult: Sendable {
    let id: String
    let step: PromptRole
    let passed: Bool
    let roles: [PromptRole]
    let failure: String?
    let formatChecks: [FormatCheck]
}

/// Forwards every call to the model under test and records the system prompt, policy and reply of each call.
@MainActor
class CallRecorder: ModelAdapter {
    private let inner: any ModelAdapter
    private(set) var recorded: [(system: String, policy: RoutePolicy, text: String)] = []

    init(_ inner: any ModelAdapter) { self.inner = inner }

    func generate(system: String, user: String, policy: RoutePolicy) async throws -> ModelReply {
        do {
            let reply = try await inner.generate(system: system, user: user, policy: policy)
            recorded.append((system, policy, reply.text))
            return reply
        } catch {
            recorded.append((system, policy, "<no reply: \(error)>"))
            throw error
        }
    }
}

/// Returns scripted replies in order, repeating the last one when the script runs out.
@MainActor
class ScriptedReplies: ModelAdapter {
    private var replies: [String]

    init(_ replies: [String]) { self.replies = replies }

    func generate(system: String, user: String, policy: RoutePolicy) async throws -> ModelReply {
        let text = replies.count > 1 ? replies.removeFirst() : (replies.first ?? "")
        return ModelReply(text: text, route: .onDevice, modelName: "scripted", seconds: 0)
    }
}

/// The data-structure contract of each step's reply, checked strictly: the whole reply must be one JSON object.
nonisolated enum ReplyFormat {
    static let intentNames: Set<String> = ["note", "task", "discuss", "unclear"]

    /// Nil when the reply conforms to the step's contract.
    static func problem(_ role: PromptRole?, _ reply: String) -> String? {
        guard let role else { return "no step matched the prompt" }
        guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] else {
            return "reply is not one JSON object"
        }
        switch role {
        case .intentClassify, .intentClassifyRepair:
            return classifyProblem(object)
        case .intentTask, .intentTaskRepair:
            return toolProblem(object, tools: ["remember"], types: ["Task"])
        case .intentAnswer, .intentAnswerFollowUp:
            return toolProblem(object, tools: ["recall", "due"], types: [])
        case .intentClarify:
            return toolProblem(object, tools: [], types: [])
        }
    }

    /// `{"intents":[...]}`: only known values, no repeats, and discuss or unclear never combine with a write.
    private static func classifyProblem(_ object: [String: Any]) -> String? {
        guard Set(object.keys) == ["intents"] else { return "keys must be exactly intents" }
        guard let list = object["intents"] as? [String] else { return "intents must be an array of strings" }
        if list.isEmpty { return "intents is empty" }
        if let bad = list.first(where: { !intentNames.contains($0) }) { return "unknown intent \"\(bad)\"" }
        let set = Set(list)
        if set.count != list.count { return "intents repeats a value" }
        if set.contains("discuss") || set.contains("unclear"), set.contains("note") || set.contains("task") {
            return "discuss or unclear cannot combine with note or task"
        }
        if set.contains("discuss"), set.contains("unclear") { return "discuss and unclear cannot combine" }
        return nil
    }

    /// `{"calls":[{"tool":...,"args":{...}}],"say":"..."}` with only the tools and types the step allows.
    private static func toolProblem(_ object: [String: Any], tools: Set<String>, types: Set<String>) -> String? {
        guard Set(object.keys) == ["calls", "say"] else { return "keys must be exactly calls and say" }
        guard object["say"] is String else { return "say must be a string" }
        guard let calls = object["calls"] as? [Any] else { return "calls must be an array" }
        for (index, item) in calls.enumerated() {
            let n = index + 1
            guard let call = item as? [String: Any] else { return "call \(n) is not an object" }
            guard Set(call.keys) == ["tool", "args"] else { return "call \(n) keys must be exactly tool and args" }
            guard let tool = call["tool"] as? String, tools.contains(tool) else { return "call \(n) tool is not allowed in this step" }
            guard let args = call["args"] as? [String: Any] else { return "call \(n) args must be an object" }
            guard tool == "remember" else { continue }
            guard let type = args["type"] as? String, types.contains(type) else { return "call \(n) type is not allowed in this step" }
            guard type == "Task" else { continue }
            guard let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "call \(n) Task needs a title"
            }
            if let due = args["due"] {
                guard let text = due as? String, isLocalDateTime(text) else { return "call \(n) due must be an ISO local date-time" }
            }
        }
        return nil
    }

    /// `2026-11-27T09:00:00` or `2026-11-27T09:00`.
    static func isLocalDateTime(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }
}

nonisolated enum StepEval {
    static let landlordTask = NewTask(id: "t-landlord", title: "Call the landlord",
                                      due: DateParsing.parse("2026-11-27T09:00:00", in: TurnEval.zone), about: nil)
    static let landlordAnswer = #"{"calls":[],"say":"You have one task: call the landlord."}"#
    static let recall = #"{"calls":[{"tool":"recall","args":{"text":"landlord"}}],"say":""}"#
    static let invalid = #"{"calls":[{"tool":"remember","args":{"type":"Nope"}}],"say":""}"#
    /// A real model reply: the calls array is never closed, and the link key sits outside the args.
    static let malformed = #"{"calls":[{"tool":"remember","args":{"type":"note","id":"1","kind":"note","title":"Park walk tomorrow","body":"Plan a park walk tomorrow","status":"active","created_at": "2026-11-21T14:32:28+01:00","updated_at": "2026-11-21T14:32:28+01:00"},"link mentions":["1"]}}, "say": "Park walk noted for tomorrow."}"#
    static func taskReply(_ title: String) -> String {
        #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"\#(title)"}}],"say":"Added."}"#
    }

    /// Every step of the intent workflow. Corpus messages give one classify, task, answer and clarify case each.
    static func cases() -> [StepCase] {
        var out: [StepCase] = [
            // intent · clarify: an unclear message gets a reply from the model, with no writes.
            StepCase(id: "I-clarify", workflow: .intent, step: .intentClarify, text: "Remind me to call the landlord Friday morning.",
                     policy: .forceOnDevice, seed: [],
                     replies: [#"{"intents":["unclear"]}"#, #"{"calls":[],"say":"Which time on Friday?"}"#], live: false) { r in
                rolesAre(r, [.intentClassify, .intentClarify]) ?? writes(r, notes: 0, tasks: 0)
                    ?? says(r, "Which time on Friday?")
            },

            // intent · classifyRepair: an invalid classifier reply is asked again.
            StepCase(id: "I-classifyRepair", workflow: .intent, step: .intentClassifyRepair, text: "Buy milk.",
                     policy: .forceOnDevice, seed: [],
                     replies: ["Sorry, I can't.", #"{"intents":["task"]}"#, taskReply("Buy milk")], live: false) { r in
                rolesAre(r, [.intentClassify, .intentClassifyRepair, .intentTask]) ?? writes(r, notes: 0, tasks: 1)
            },

            // intent · classify again through escalation: after the repair fails, the classifier runs once in cloud.
            StepCase(id: "I-classifyEscalate", workflow: .intent, step: .intentClassify, text: "Buy milk.",
                     policy: .auto, seed: [],
                     replies: ["Sorry.", "Still no.", #"{"intents":["task"]}"#, taskReply("Buy milk")], live: false) { r in
                rolesAre(r, [.intentClassify, .intentClassifyRepair, .intentClassify, .intentTask])
                    ?? policyIs(r, call: 2, .forceCloud) ?? writes(r, notes: 0, tasks: 1)
            },

            // intent · taskRepair: a rejected task reply is repaired once, with the task-only prompt.
            StepCase(id: "I-taskRepair", workflow: .intent, step: .intentTaskRepair, text: "Buy milk.",
                     policy: .forceOnDevice, seed: [],
                     replies: [#"{"intents":["task"]}"#, invalid, taskReply("Buy milk")], live: false) { r in
                rolesAre(r, [.intentClassify, .intentTask, .intentTaskRepair]) ?? writes(r, notes: 0, tasks: 1)
            },

            // intent · answerFollowUp: a read returns items, and the answer is written from them.
            StepCase(id: "I-answerFollowUp", workflow: .intent, step: .intentAnswerFollowUp, text: "What's on my list?",
                     policy: .forceOnDevice, seed: [landlordTask],
                     replies: [#"{"intents":["discuss"]}"#, recall, landlordAnswer], live: false) { r in
                rolesAre(r, [.intentClassify, .intentAnswer, .intentAnswerFollowUp]) ?? says(r, "You have one task: call the landlord.")
            },
        ]

        // intent · classify: every corpus message, the classifier's intents against the labels.
        for c in TurnEval.corpus {
            out.append(StepCase(id: "I-classify-\(c.id)", workflow: .intent, step: .intentClassify, text: c.text,
                                policy: .forceOnDevice, seed: [], replies: c.intentReplies, live: true) { r in
                first(r, .intentClassify) ?? intentsAre(r, c.intents)
            })
        }

        // intent · task: every corpus action, one Task per action with the due time, and a Note when the message has one.
        for c in TurnEval.corpus where c.expect == .task || c.expect == .mixed {
            out.append(StepCase(id: "I-task-\(c.id)", workflow: .intent, step: .intentTask, text: c.text,
                                policy: .forceOnDevice, seed: [], replies: c.intentReplies, live: true) { r in
                ran(r, .intentTask) ?? writes(r, notes: c.notes, tasks: c.tasks) ?? dueIs(r, c.due)
            })
        }

        // intent · answer: questions and greetings, answered in words with no writes.
        for c in TurnEval.corpus where c.expect == .question || c.expect == .greeting {
            out.append(StepCase(id: "I-answer-\(c.id)", workflow: .intent, step: .intentAnswer, text: c.text,
                                policy: .forceOnDevice, seed: [], replies: c.intentReplies, live: true) { r in
                ran(r, .intentAnswer) ?? writes(r, notes: 0, tasks: 0) ?? (r.say.isEmpty ? "no answer in say" : nil)
            })
        }

        // intent · clarify on the live model: unclear messages from the corpus, answered with no writes.
        for c in TurnEval.corpus where c.expect == .clarify {
            out.append(StepCase(id: "I-clarify-\(c.id)", workflow: .intent, step: .intentClarify, text: c.text,
                                policy: .forceOnDevice, seed: [], replies: c.intentReplies, live: true) { r in
                ran(r, .intentClarify) ?? writes(r, notes: 0, tasks: 0) ?? (r.say.isEmpty ? "no question in say" : nil)
            })
        }
        return out
    }

    /// Runs the cases of one workflow under one prompt set. Live runs keep only the cases that a real model can run.
    static func run(_ cases: [StepCase], workflow: WorkflowID, prompts: PromptSet, live: Bool,
                    model: (StepCase) async -> any ModelAdapter) async throws -> [StepResult] {
        let heads = promptHeads(workflow, prompts)
        var results: [StepResult] = []
        for c in cases where c.workflow == workflow && (!live || c.live) {
            let store = try makeMemoryStore()
            if !c.seed.isEmpty { try await store.addTasks(c.seed, now: TurnEval.now) }
            let recorder = await CallRecorder(await model(c))
            let assistant = Assistant(store: store, model: recorder, clock: { TurnEval.now },
                                      timeZone: TurnEval.zone, workflow: workflow, prompts: prompts)
            let turn = try await assistant.handle(c.text, policy: c.policy)

            let seeded = Set(c.seed.map(\.id))
            let notes = try await store.recentNotes(limit: 1000).count
            let tasks = try await store.openTasks().filter { !seeded.contains($0.id) }
            let due = tasks.compactMap(\.due).first.map { DateParsing.formatLocal($0, in: TurnEval.zone) }

            let calls = await recorder.recorded.map { StepCall(role: role(of: $0.system, heads), policy: $0.policy, reply: $0.text) }
            let run = StepRun(calls: calls, notes: notes, tasks: tasks.count, due: due,
                              intents: turn.intents, say: turn.say)
            let failure = c.check(run)
            let formats = calls.map { FormatCheck(role: $0.role, problem: ReplyFormat.problem($0.role, $0.reply), reply: $0.reply) }
            results.append(StepResult(id: c.id, step: c.step, passed: failure == nil, roles: run.roles,
                                      failure: failure, formatChecks: formats))
        }
        return results
    }

    /// The first 60 characters of every step's prompt for one cell. Two steps sharing an opening would be mis-attributed.
    static func promptHeads(_ workflow: WorkflowID, _ prompts: PromptSet) -> [(PromptRole, String)] {
        let context = PromptContext(now: TurnEval.now, timeZone: TurnEval.zone, digest: "", noteId: "eval")
        return (PromptFactory.factory(for: workflow)?.renderAll(prompts, context) ?? [:]).map { ($0.key, String($0.value.prefix(60))) }
    }

    private static func role(of system: String, _ heads: [(PromptRole, String)]) -> PromptRole? {
        heads.first { system.hasPrefix($0.1) }?.0
    }

    static func report(_ results: [StepResult], title: String, withFormat: Bool) -> String {
        var lines = ["== \(title)", "id                  step                  result  steps"]
        for r in results {
            lines.append("\(padded(r.id, 19)) \(padded(r.step.rawValue, 21)) \(r.passed ? "PASS" : "FAIL")    \(r.roles.map(\.rawValue).joined(separator: " > "))")
            if let f = r.failure { lines.append("     -> \(f)") }
        }
        var steps: [PromptRole] = []
        for r in results where !steps.contains(r.step) { steps.append(r.step) }
        for s in steps {
            let rs = results.filter { $0.step == s }
            lines.append("\(s.rawValue): \(rs.filter { $0.passed }.count)/\(rs.count)")
        }
        lines.append("total: \(results.filter { $0.passed }.count)/\(results.count)")
        if withFormat { lines.append(formatSummary(results)) }
        return lines.joined(separator: "\n")
    }

    /// Contract conformance of every reply, per step, with each broken reply printed in full.
    static func formatSummary(_ results: [StepResult]) -> String {
        let checks = results.flatMap(\.formatChecks)
        var lines = ["== reply format (data-structure contract)"]
        for role in PromptRole.allCases {
            let rs = checks.filter { $0.role == role }
            if rs.isEmpty { continue }
            lines.append("\(role.rawValue): \(rs.filter { $0.problem == nil }.count)/\(rs.count) conform")
            for bad in rs {
                if let problem = bad.problem { lines.append("     -> \(problem) | reply: \(bad.reply)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func padded(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    // MARK: checks. Each returns nil when the step behaved.

    static func ran(_ r: StepRun, _ role: PromptRole) -> String? {
        r.roles.contains(role) ? nil : "step \(role.rawValue) did not run; steps \(r.roles.map(\.rawValue))"
    }

    static func first(_ r: StepRun, _ role: PromptRole) -> String? {
        r.roles.first == role ? nil : "first step \(r.roles.first?.rawValue ?? "none"), expected \(role.rawValue)"
    }

    static func rolesAre(_ r: StepRun, _ want: [PromptRole]) -> String? {
        r.roles == want ? nil : "steps \(r.roles.map(\.rawValue)), expected \(want.map(\.rawValue))"
    }

    static func writes(_ r: StepRun, notes: Int, tasks: Int) -> String? {
        r.notes == notes && r.tasks == tasks ? nil : "notes \(r.notes), tasks \(r.tasks); expected \(notes) and \(tasks)"
    }

    static func says(_ r: StepRun, _ want: String) -> String? {
        r.say == want ? nil : "say \"\(r.say)\", expected \"\(want)\""
    }

    static func policyIs(_ r: StepRun, call: Int, _ want: RoutePolicy) -> String? {
        r.calls[call].policy == want ? nil : "call \(call) policy \(r.calls[call].policy), expected \(want)"
    }

    static func intentsAre(_ r: StepRun, _ want: Set<Intent>) -> String? {
        Set(r.intents) == want ? nil : "intents \(r.intents.map(\.rawValue)), expected \(want.map(\.rawValue).sorted())"
    }

    static func dueIs(_ r: StepRun, _ want: String?) -> String? {
        guard let want else { return nil }
        return (r.due ?? "").hasPrefix(want) ? nil : "due \(r.due ?? "none"), expected \(want)"
    }
}

private let stepLiveEnabled = ProcessInfo.processInfo.environment["POCKET_EVAL"] == "1"

@Suite struct StepEvalTests {
    @Test func malformedReplyIsRejectedWithItsReason() {
        guard case .failure(let problem) = ToolExecutor.parseReply(StepEval.malformed) else {
            Issue.record("the malformed reply parsed")
            return
        }
        #expect(problem.message.hasPrefix("reply is not valid JSON: "), "reason: \(problem.message)")
        #expect(problem.message.count > "reply is not valid JSON: ".count, "the reason names the error")
    }

    @Test func formatCheckerAcceptsConformingReplies() {
        let replies: [(PromptRole, String)] = [
            (.intentClassify, #"{"intents":["note","task"]}"#),
            (.intentClassifyRepair, #"{"intents":["discuss"]}"#),
            (.intentTask, StepEval.taskReply("Buy milk")),
            (.intentTask, #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"Call the landlord","due":"2026-11-27T09:00:00","about":"n1"}}],"say":"Added."}"#),
            (.intentTaskRepair, StepEval.taskReply("Buy milk")),
            (.intentAnswer, StepEval.landlordAnswer),
            (.intentAnswer, StepEval.recall),
            (.intentAnswerFollowUp, StepEval.landlordAnswer),
            (.intentClarify, #"{"calls":[],"say":"Which time on Friday?"}"#),
        ]
        for (role, reply) in replies {
            #expect(ReplyFormat.problem(role, reply) == nil, "\(role.rawValue) should conform: \(reply)")
        }
    }

    @Test func formatCheckerRejectsBrokenReplies() {
        let replies: [(PromptRole, String)] = [
            (.intentClassify, "Sorry, I can't."),
            (.intentClassify, #"Here you go: {"intents":["note"]}"#),
            (.intentClassify, #"{"intents":[]}"#),
            (.intentClassify, #"{"intents":["Note"]}"#),
            (.intentClassify, #"{"intents":["note","note"]}"#),
            (.intentClassify, #"{"intents":["note","discuss"]}"#),
            (.intentClassify, #"{"intents":["unclear","task"]}"#),
            (.intentClassify, #"{"intents":["note"],"say":"ok"}"#),
            (.intentTask, StepEval.malformed),
            (.intentTask, #"{"calls":[{"tool":"remember","args":{"type":"Note","title":"x"}}],"say":"ok"}"#),
            (.intentTask, #"{"calls":[{"tool":"remember","args":{"type":"Task"}}],"say":"ok"}"#),
            (.intentTask, #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"x","due":"tomorrow"}}],"say":"ok"}"#),
            (.intentTask, #"{"calls":[],"say":"ok","extra":1}"#),
            (.intentTask, #"{"calls":[]}"#),
            (.intentAnswer, #"{"calls":[{"tool":"remember","args":{"type":"Task","title":"x"}}],"say":"ok"}"#),
            (.intentClarify, #"{"calls":[{"tool":"recall","args":{"text":"x"}}],"say":"ok"}"#),
        ]
        for (role, reply) in replies {
            #expect(ReplyFormat.problem(role, reply) != nil, "\(role.rawValue) should be rejected: \(reply)")
        }
    }

    @Test func everyStepHasAnEvalCase() {
        for (workflow, _) in TurnEval.matrix {
            let covered = Set(StepEval.cases().filter { $0.workflow == workflow }.map(\.step))
            let steps = Set(PromptFactory.factory(for: workflow)?.templates.map(\.role) ?? [])
            #expect(steps.isSubset(of: covered), "\(workflow.rawValue): steps without an eval: \(steps.subtracting(covered).map(\.rawValue))")
        }
    }

    @Test func promptOpeningsAreDistinctInEveryCell() throws {
        for (workflow, prompts) in TurnEval.matrix {
            let heads = StepEval.promptHeads(workflow, prompts).map(\.1)
            #expect(Set(heads).count == heads.count, "\(prompts.name): two steps share a prompt opening")
        }
    }

    @Test func oracleStepsPassEveryMatrixCell() async throws {
        for (workflow, prompts) in TurnEval.matrix {
            let results = try await StepEval.run(StepEval.cases(), workflow: workflow, prompts: prompts, live: false) { c in
                await ScriptedReplies(c.replies)
            }
            print(StepEval.report(results, title: "\(workflow.rawValue) / \(prompts.name) (steps, oracle)", withFormat: false))
            #expect(results.allSatisfy { $0.passed }, "scripted steps must pass for \(workflow.rawValue) / \(prompts.name)")
        }
    }

    /// Real model. Every reply must conform to its step's contract, the classifier first among them.
    @Test(.enabled(if: stepLiveEnabled)) func liveSteps() async throws {
        let backend = ProcessInfo.processInfo.environment["POCKET_EVAL_BACKEND"] ?? "apple"
        for (workflow, prompts) in TurnEval.matrix {
            let results = try await StepEval.run(StepEval.cases(), workflow: workflow, prompts: prompts, live: true) { _ in
                backend == "firebase" ? FirebaseModelAdapter() as any ModelAdapter : FoundationModelsAdapter() as any ModelAdapter
            }
            print("LIVE STEPS backend=\(backend)")
            print(StepEval.report(results, title: "\(workflow.rawValue) / \(prompts.name) (steps, live)", withFormat: true))

            let broken = results.flatMap(\.formatChecks).filter { $0.problem != nil }
            #expect(broken.isEmpty, "\(backend): \(broken.count) replies break their contract; first: \(broken.first?.problem ?? "")")
        }
    }
}
