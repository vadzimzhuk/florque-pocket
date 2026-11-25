import Foundation

// Purpose: the `cer` workflow's prompts. One system prompt per step (and per repair), kept short for a local model.
// The classify prompt lists the six classifier values, each with an example. The extract prompt names only the one tool
// the classifier chose, so it stays small. The user side carries the message, recent chat, and (for respond) the results.
// Every system prompt names its JSON reply shape.
//
// Testing: `CERTests` checks that each prompt names its reply shape, that the classify prompt has the six values with
// examples, and that the extract prompt lists only the chosen tool.

nonisolated enum CERPrompts {
    static func classify(now: Date, timeZone: TimeZone) -> String {
        """
        Classify what the user wants to DO. Reply with one JSON object only: {"intent":"<value>","reason":"<=25 words"}.
        Values: record_note, record_event, retrieve_notes, retrieve_events, chat, unclear.
        The value is an action, never a thing: "event" and "note" are not values.
        record_note: save something to remember. "Wifi code is 4411" -> record_note
        record_event: something that happens at a date and time, even if the time is not given yet. "Interview tomorrow at 10:00" -> record_event
        retrieve_notes: look up saved notes. "What did I note about wifi?" -> retrieve_notes
        retrieve_events: look up saved events. "What events do I have tomorrow?" -> retrieve_events
        chat: greeting, thanks or small talk. "hi" -> chat
        unclear: you cannot tell what to do. "tomorrow" -> unclear
        Now: \(DateParsing.formatLocal(now, in: timeZone)) (\(timeZone.identifier)).
        """
    }

    static let classifyRepair = """
        Your last reply was not valid. Reply with only one JSON object: {"intent":"<value>","reason":"<=25 words"}. Values: record_note, record_event, retrieve_notes, retrieve_events, chat, unclear. "event" and "note" alone are not values: use record_event for an event, record_note for a note.
        """

    static func extract(tool: any CERTool, now: Date, timeZone: TimeZone) -> String {
        """
        Fill the arguments of one tool for the user's message. Reply with one JSON object only: {"args":{...}}.
        Tool: \(tool.catalogLine)
        Example: \(tool.exampleArgs)
        Dates are ISO local date-times, e.g. 2026-11-27T09:00:00. Now: \(DateParsing.formatLocal(now, in: timeZone)) (\(timeZone.identifier)).
        Leave out what the message does not give; do not invent a value.
        """
    }

    static func extractRepair(tool: any CERTool, now: Date, timeZone: TimeZone) -> String {
        """
        Your reply was rejected; the reason is in the message. Reply with only one JSON object: {"args":{...}}.
        Tool: \(tool.catalogLine)
        Example: \(tool.exampleArgs)
        Now: \(DateParsing.formatLocal(now, in: timeZone)) (\(timeZone.identifier)).
        """
    }

    static let respond = """
        Reply to the user in a friendly message. If the user complains or asks - try to help. In case of offence or provoking you - respond as psychologist. Reply with one JSON object only: {"say":"..."}.
        Report about any actions done only based on RESULTS. If RESULTS is empty and the intent is chat, respond based on MESSAGE and HISTORY. If you feel something is missing, ask for it in one short question. Never say something was saved unless RESULTS says so.
        """

    static let respondRepair = """
        Reply with only one JSON object: {"say":"..."}, one short message, using only the RESULTS in the message.
        """

    static let clarify = """
        Ask the user one short question to get what is missing. Reply with only one JSON object: {"say":"..."}.
        """
}
