import Foundation

// Purpose: a one-line description of the `intent` app state, for the debug log after each step.
// Testing: read in the console of a DEBUG run; the description has no logic beyond formatting.

extension IntentTurnState {
    /// The state as one console line: the fields a step can change, with the say text and any rejections.
    var logSummary: String {
        var parts = [
            "intents=\(intents.map(\.rawValue).sorted())",
            "classifyOK=\(classifyOK)",
            "repairs=\(classifyRepairs)",
            "escalated=\(escalated)",
            "classifyFailed=\(classifyFailed)",
            "noteDone=\(noteDone)",
            "actionDone=\(actionDone)",
            "answered=\(answered)",
            "results=\(results.count)",
            "followedUp=\(followedUp)",
            "clarifyNeeded=\(clarifyNeeded)",
            "taskIds=\(taskIds)",
            "reminderFailed=\(reminderFailed)",
            "route=\"\(route)\"",
            "say=\"\(say)\"",
        ]
        if !rejections.isEmpty { parts.append("rejections=\(rejections)") }
        return parts.joined(separator: " ")
    }
}
