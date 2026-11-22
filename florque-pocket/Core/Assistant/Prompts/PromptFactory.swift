import Foundation

// Purpose: the prompt registry. Each step's system prompt is a versioned template, and a `PromptSet` names the
// version each workflow uses. Old versions stay registered, so an eval can run any of them.
// Testing: `StepEvalTests.promptOpeningsAreDistinctInEveryCell` (steps cannot be confused) and
// `everyStepHasAnEvalCase` (every step has an eval).

/// Every model prompt the app sends. One role is one system prompt, sent by one step of one workflow.
/// A step that repeats an instruction with a different route (for example escalation) reuses its role's prompt.
nonisolated enum PromptRole: String, Sendable, CaseIterable {
    // `intent`: classify, then a task or a read answer, each with its repair.
    case intentClassify, intentClassifyRepair
    case intentTask, intentTaskRepair
    case intentAnswer, intentAnswerFollowUp
    /// Replies to chat, greetings and unclear messages, with no writes.
    case intentClarify
}

/// Inputs a template may use. Templates ignore what they do not need.
nonisolated struct PromptContext: Sendable {
    let now: Date
    let timeZone: TimeZone
    let digest: String
    let noteId: String
}

/// One step's prompt at one version. Ship a new version as a new type, never edit a shipped one.
nonisolated protocol PromptTemplate: Sendable {
    var role: PromptRole { get }
    var version: String { get }
    func render(_ context: PromptContext) -> String
}

/// The prompts one workflow sends: a template per step, for every version the workflow supports.
nonisolated protocol WorkflowPromptFactory: Sendable {
    var workflow: WorkflowID { get }
    var templates: [any PromptTemplate] { get }
    /// The version this workflow uses from a prompt set.
    func version(in set: PromptSet) -> String
}

extension WorkflowPromptFactory {
    /// Renders one system prompt per step, at the version the prompt set names.
    /// Fails when a step has no template at that version, so a missing prompt cannot reach a model.
    func renderAll(_ set: PromptSet, _ context: PromptContext) -> [PromptRole: String] {
        let v = version(in: set)
        var out: [PromptRole: String] = [:]
        for role in Set(templates.map(\.role)) {
            out[role] = render(role, v, context)
        }
        return out
    }

    func render(_ role: PromptRole, _ version: String, _ context: PromptContext) -> String {
        guard let template = templates.first(where: { $0.role == role && $0.version == version }) else {
            fatalError("No prompt \(role.rawValue) \(version) is registered for \(workflow.rawValue)")
        }
        return template.render(context)
    }

    /// The versions registered for one step, in registration order.
    func versions(of role: PromptRole) -> [String] {
        templates.filter { $0.role == role }.map(\.version)
    }
}

/// Registry of the workflow factories. `cer` keeps its prompts in `CERPrompts` (static text, no factory), so it has none.
nonisolated enum PromptFactory {
    static func factory(for workflow: WorkflowID) -> (any WorkflowPromptFactory)? {
        switch workflow {
        case .intent: IntentPromptFactory()
        case .cer: nil
        }
    }
}

extension Dictionary where Key == PromptRole, Value == String {
    /// The rendered prompt for a step. A step that was never rendered is a wiring bug.
    func prompt(_ role: PromptRole) -> String {
        guard let text = self[role] else { fatalError("No rendered prompt for \(role.rawValue)") }
        return text
    }
}

/// One named combination of prompt versions, used by the eval matrix and the DEBUG picker.
nonisolated struct PromptSet: Sendable, Equatable {
    let name: String
    let intentVersion: String

    static let intentV1 = PromptSet(name: "intent-v1", intentVersion: "v1")
    static let all: [PromptSet] = [intentV1]
    static let current = intentV1
}
