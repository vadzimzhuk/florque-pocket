import Foundation

// Purpose: the `cer` workflow's prompts. One system prompt per step (and per repair), kept short for a local model.
// Only the extract prompt grows with the intent, because it lists just that intent's tools. The user side carries the
// message, the last few chat lines, and (for respond) the tool results. Every system prompt names its JSON reply shape.
//
// Testing: `CERPromptTests` checks that each prompt names its reply shape and that every prompt, filled with the
// largest inputs, stays under the token budget.

nonisolated enum CERPrompts {
    static func classify(now: Date, timeZone: TimeZone) -> String {
        """
        Classify what the user wants to DO. Reply with one JSON object only: {"intent":"record|retrieve|chat|unclear","reason":"<=25 words"}.
        The intent is an action. "event" and "note" are things, never intents.
        record: save something new, a note or an event with a date and time. "Dentist Friday 9am" -> record
        retrieve: look up what is already saved. "What events do I have tomorrow?" -> retrieve
        chat: greeting, thanks or small talk. "hi" -> chat
        unclear: you cannot tell what to do. "tomorrow" -> unclear
        If a message both saves and looks up, choose record.
        Now: \(DateParsing.formatLocal(now, in: timeZone)) (\(timeZone.identifier)).
        """
    }

    static let classifyRepair = """
        Your last reply was not valid. Reply with only one JSON object: {"intent":"record|retrieve|chat|unclear","reason":"<=25 words"}. Use only those four intent values. "event" and "note" are not intents: use record to save one, retrieve to look one up.
        """

    static func extract(intent: CERIntent, now: Date, timeZone: TimeZone) -> String {
        """
        Choose the tools for the user's message and fill their arguments. Reply with one JSON object only: {"calls":[{"tool":"NAME","args":{...}}],"missing":[]}.
        Use only these tools, at most 3 calls:
        \(toolLines(intent))
        Dates are ISO local date-times, e.g. 2026-11-27T09:00:00. Now: \(DateParsing.formatLocal(now, in: timeZone)) (\(timeZone.identifier)).
        An event without a date and time: leave its call out and put "time" in missing. For chat, reply {"calls":[],"missing":[]}.
        """
    }

    static func extractRepair(intent: CERIntent, now: Date, timeZone: TimeZone) -> String {
        """
        Your reply was rejected; the reason is in the message. Reply with only one JSON object: {"calls":[{"tool":"NAME","args":{...}}],"missing":[]}.
        Use only these tools:
        \(toolLines(intent))
        Now: \(DateParsing.formatLocal(now, in: timeZone)) (\(timeZone.identifier)).
        """
    }

    static let respond = """
        Reply to the user in one short, friendly message. Reply with one JSON object only: {"say":"..."}.
        Answer only from RESULTS. If RESULTS is empty and the intent is chat, greet and ask how you can help. If something is missing, ask for it in one short question. Never say something was saved unless RESULTS says so.
        """

    static let respondRepair = """
        Reply with only one JSON object: {"say":"..."}, one short message, using only the RESULTS in the message.
        """

    static let clarify = """
        Ask the user one short question to get what is missing. Reply with only one JSON object: {"say":"..."}.
        """

    private static func toolLines(_ intent: CERIntent) -> String {
        let lines = CERToolbox.catalog(for: intent)
        return lines.isEmpty ? "(none: this message needs no tool)" : lines
    }
}
