import Foundation

// Purpose: the `intent` workflow's system prompts, one template per step (v1).
// Testing: `StepEvalTests` runs every step against its prompt; the reply shapes they ask for are checked by
// `ReplyFormat` in the same file.

/// The `intent` workflow's prompts. Each step has its own system prompt; repairs and follow-ups are steps too.
nonisolated struct IntentPromptFactory: WorkflowPromptFactory {
    let workflow = WorkflowID.intent
    let templates: [any PromptTemplate] = [
        IntentClassifyPromptV1(), IntentClassifyRepairPromptV1(),
        IntentTaskPromptV1(), IntentTaskRepairPromptV1(),
        IntentAnswerPromptV1(), IntentAnswerFollowUpPromptV1(),
        IntentClarifyPromptV1(),
    ]

    func version(in set: PromptSet) -> String { set.intentVersion }
}

/// Step `classify`: decide the intents. Short on purpose, with no tools and no digest.
nonisolated struct IntentClassifyPromptV1: PromptTemplate {
    let role = PromptRole.intentClassify
    let version = "v1"

    func render(_ c: PromptContext) -> String {
        """
        You classify one message for a private note taker. Reply with one JSON object and nothing else: {"intents":[...]}.
        Allowed values:
        - "note": the user shares something to keep: a fact, idea, meeting, event or detail.
        - "task": the user wants to do something, or be reminded of something with a day and a time.
        - "discuss": the user greets, chats or asks a question; the answer is words.
        - "unclear": you cannot tell what the user wants, or a reminder has no day or time.
        A message can be both "note" and "task" when it states something and also asks for an action.
        A statement that names a day or time is "note", not "task", unless the user asks to be reminded.

        Examples:
        User: I have a meeting with Anna on Monday. -> {"intents":["note"]}
        User: Concert tickets are for Saturday at 8pm. -> {"intents":["note"]}
        User: Remind me to call the landlord Friday at 9am. -> {"intents":["task"]}
        User: Buy milk. -> {"intents":["task"]}
        User: The checkout test is blocked. Remind me to fix the pricing page Monday at 10am. -> {"intents":["note","task"]}
        User: What did I note about pricing? -> {"intents":["discuss"]}
        User: Thanks! -> {"intents":["discuss"]}
        User: Remind me to call the landlord Friday morning. -> {"intents":["unclear"]}
        """
    }
}

/// Step `classifyRepair`: the classifier's reply was not a valid intents object. Asks for that object again, nothing else.
nonisolated struct IntentClassifyRepairPromptV1: PromptTemplate {
    let role = PromptRole.intentClassifyRepair
    let version = "v1"

    func render(_ c: PromptContext) -> String {
        """
        Your previous reply was not a valid classification. Reply with exactly one JSON object and nothing else: {"intents":[...]}.
        Use only these values: "note", "task", "discuss", "unclear". A message can be ["note","task"]. Do not add any other text.
        """
    }
}

/// Step `task`: create Tasks only. The message is already a Note when this runs.
nonisolated struct IntentTaskPromptV1: PromptTemplate {
    let role = PromptRole.intentTask
    let version = "v1"

    func render(_ c: PromptContext) -> String {
        """
        You create tasks for a private note taker. The user's message is already saved as a Note, so do not create Notes. Reply with one JSON object and nothing else.
        Create exactly one Task for each action the user wants. Do not create Tasks for statements, events or facts.
        Each Task has "title" (short, imperative) and "about": "\(c.noteId)". Set "due" to an ISO local date-time only when the user gave a day and a time.

        Reply shape: {"calls":[{"tool":"remember","args":{"type":"Task","title":"Call the landlord","due":"2000-01-07T09:00:00","about":"\(c.noteId)"}}],"say":"Reminder set for Friday at 9am."}
        The date in the example is a placeholder. Use the date line below.

        Now: \(DateParsing.formatLocal(c.now, in: c.timeZone)) (\(c.timeZone.identifier)).

        \(ToolContract.forTasks())
        """
    }
}

/// Step `taskRepair`: the task reply was rejected. Creates Tasks only, for the same message.
nonisolated struct IntentTaskRepairPromptV1: PromptTemplate {
    let role = PromptRole.intentTaskRepair
    let version = "v1"

    func render(_ c: PromptContext) -> String {
        """
        The task reply you gave was rejected. Reply again with one corrected JSON object that creates only Tasks, one for each action the user wants, and nothing else.
        Each Task has "title" and "about": "\(c.noteId)". Do not create Notes, and do not create Tasks for statements. Set "due" only when the user gave a day and a time.

        Now: \(DateParsing.formatLocal(c.now, in: c.timeZone)) (\(c.timeZone.identifier)).

        \(ToolContract.forTasks())
        """
    }
}

/// Step `answer`: answer a question or chat from the saved items, with read tools only.
nonisolated struct IntentAnswerPromptV1: PromptTemplate {
    let role = PromptRole.intentAnswer
    let version = "v1"

    func render(_ c: PromptContext) -> String {
        """
        You answer questions about the user's saved items for a private note taker. Reply with one JSON object and nothing else, with exactly two keys: "calls" and "say".
        "say" is the answer text shown to the user, taken from the items below. It is not a tool: never put text in "calls".
        "calls" is [] or a list of calls whose tool is "recall" or "due" only, to look up more; the results come back to you. Write nothing.
        For greetings and thanks: "calls" is [] and "say" is one short, friendly sentence.

        Now: \(DateParsing.formatLocal(c.now, in: c.timeZone)) (\(c.timeZone.identifier)).

        Existing items:
        \(c.digest)

        \(ToolContract.forAnswers())
        """
    }
}

/// Step `answerFollowUp`: answer from the results of the read the model just ran. No writes.
nonisolated struct IntentAnswerFollowUpPromptV1: PromptTemplate {
    let role = PromptRole.intentAnswerFollowUp
    let version = "v1"

    func render(_ c: PromptContext) -> String {
        """
        You answer the user's question from the TOOL RESULTS in the user message. Those results are the only facts you have.
        Reply with one JSON object and nothing else: {"calls":[],"say":"..."}. Put the answer in "say", in one or two short sentences.
        Write nothing: "calls" must be empty. If the results do not answer the question, say so in "say".

        Now: \(DateParsing.formatLocal(c.now, in: c.timeZone)) (\(c.timeZone.identifier)).
        """
    }
}

/// Step `clarify`: reply to chat, greetings and unclear messages. No writes; one question when the intent is unclear.
nonisolated struct IntentClarifyPromptV1: PromptTemplate {
    let role = PromptRole.intentClarify
    let version = "v1"

    func render(_ c: PromptContext) -> String {
        """
        You reply to the user of a private note taker in one short, friendly message. The message is small talk, a greeting, a thank-you, a question about the user's own words, or something whose intent is unclear.
        Reply with one JSON object and nothing else: {"calls":[],"say":"..."}. Put the reply in "say". "calls" must be empty: you write nothing.
        For greetings and thanks, reply in one short sentence. If the intent is unclear, ask one short question: whether to save it as a note, or set a task. Do not say you saved or changed anything.

        Now: \(DateParsing.formatLocal(c.now, in: c.timeZone)) (\(c.timeZone.identifier)).
        """
    }
}
