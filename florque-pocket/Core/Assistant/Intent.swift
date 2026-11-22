import Foundation

// Purpose: the classifier's answer type and its parser. The parser accepts a reply wrapped in prose and enforces
// the combination rules in code, so the workflow never trusts the model's combinations.
// Testing: through the eval suites, which feed the parser the classifier replies: `TurnEvalTests` (whole turns)
// and `StepEvalTests` (the classify steps, including the repaired and malformed cases).

/// What the user wants from one message. A message can be a note, a task, or both.
/// `discuss` (answer in words) and `unclear` (ask a question) never combine with the write intents.
public nonisolated enum Intent: String, Sendable, CaseIterable, Hashable {
    case note, task, discuss, unclear
}

nonisolated enum IntentParser {
    private struct Reply: Decodable {
        let intents: [String]
    }

    /// Reads `{"intents": [...]}` from a model reply, tolerating prose or code fences around it.
    /// Returns nil when no valid object is present, so the workflow can repair or escalate.
    static func parse(_ text: String) -> Set<Intent>? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(text[start...end].utf8)) else { return nil }
        let known = reply.intents.compactMap { Intent(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) }
        return normalize(Set(known))
    }

    /// Enforces the combination rules in code, whatever the model returned.
    /// - note and task may combine; any write intent drops discuss and unclear.
    /// - discuss and unclear are exclusive; unclear wins over discuss.
    /// - an empty result is unclear.
    static func normalize(_ intents: Set<Intent>) -> Set<Intent> {
        let writes = intents.intersection([.note, .task])
        if !writes.isEmpty { return writes }
        if intents.contains(.unclear) { return [.unclear] }
        if intents.contains(.discuss) { return [.discuss] }
        return [.unclear]
    }
}
