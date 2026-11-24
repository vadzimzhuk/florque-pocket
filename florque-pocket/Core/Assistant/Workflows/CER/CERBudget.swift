import Foundation

// Purpose: keeps every model input of the `cer` workflow small. Local models have a 15000-token window; the whole
// input (system + user) must stay under `inputLimit`. Prompts are short and static; the variable parts (message,
// history, tool results) are capped here before they reach a prompt.
//
// Testing: `CERBudgetTests` checks the estimate, the caps, the history trimming, and that a worst-case state
// (maximum message, history and results) is still under the limit.

nonisolated enum TokenBudget {
    /// The hard limit for one model input, system and user together.
    static let inputLimit = 7000
    /// Worst-case size reserved for the system prompt and the catalog of the largest step.
    static let systemReserve = 1500
    /// A conservative estimate: Cyrillic and mixed text use more tokens per character than English.
    static let charsPerToken = 2.5

    static let maxMessageChars = 2000
    static let maxHistoryLines = 5
    static let maxHistoryLineChars = 240
    static let maxResultChars = 160 * 5

    static func estimate(_ text: String) -> Int {
        Int((Double(text.count) / charsPerToken).rounded(.up))
    }

    /// The last `maxHistoryLines` lines, each cut to `maxHistoryLineChars`. Oldest lines go first.
    static func history(_ lines: [String]) -> [String] {
        lines.suffix(maxHistoryLines).map { clip($0, maxHistoryLineChars) }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Estimated size of the variable parts of a turn, plus the reserved system size.
    static func inputTokens(text: String, history: [String], results: String) -> Int {
        systemReserve + estimate(text) + estimate(history.joined(separator: "\n")) + estimate(results)
    }
}
