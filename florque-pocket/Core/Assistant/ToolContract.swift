import Foundation

// Purpose: the reply shape and tool descriptions shown to the model. Each step gets only the tools it may use,
// matching the allow-lists that `ToolExecutor` enforces, so the prompt and the code agree.
//
// Testing: `StepEvalTests` checks that each step's replies follow the shape given here, and `ToolExecutorTests`
// checks that the executor accepts and rejects the same calls this text describes.

public enum ToolContract {
    /// For the task steps: create tasks only.
    public static func forTasks() -> String {
        """
        Reply with one JSON object and nothing else:
        {"calls":[{"tool":"remember","args":{"type":"Task","title":"<short title>","due":"<ISO local date-time, optional>","about":"<note id, optional>"}}],"say":"<short reply to the user>"}
        Tools:
        - remember: create one Task. args: type (always "Task"), title (required), due (optional ISO local date-time), about (optional id of the saved note).
        Use at most 5 calls.
        """
    }

    /// For the answer steps: read tools only, so nothing is written.
    public static func forAnswers() -> String {
        """
        Reply with one JSON object and nothing else:
        {"calls":[{"tool":"recall","args":{"text":"<words to find>"}}],"say":"<short reply to the user>"}
        Tools (read only):
        - recall: find saved notes and tasks. args: text (optional), type ("Note" or "Task", optional), limit (optional number).
        - due: list open tasks due at or before a time. args: before (ISO local date-time, required).
        Use at most 5 calls. Use the results returned to you before you answer.
        """
    }
}
