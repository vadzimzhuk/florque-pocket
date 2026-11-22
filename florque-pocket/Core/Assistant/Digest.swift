import Foundation

// Purpose: the compact view of saved items that the answer prompt sees: open tasks and recent notes, capped in
// size. It is the only saved data sent with a request, so a cloud model never receives the whole store.
//
// Testing: `AssistantTests.digestListsOpenTasksAndNotes` checks the lines for open tasks, notes and the empty case.

public enum Digest {
    /// Builds the digest from already-filtered records (active tasks and notes, as `PocketStore` returns them).
    public static func build(tasks: [TaskRecord], notes: [NoteRecord], timeZone: TimeZone, maxLines: Int = 40) -> String {
        var lines: [String] = []
        lines.append("Open tasks:")
        for t in tasks.prefix(maxLines / 2) {
            let due = t.due.map { " due \(DateParsing.formatLocal($0, in: timeZone))" } ?? ""
            lines.append("- Task \(t.id) | \(t.title) |\(due) status \(t.status.rawValue)")
        }
        if tasks.isEmpty { lines.append("- none") }
        lines.append("Recent notes:")
        for n in notes.prefix(maxLines / 2) {
            lines.append("- Note \(n.id) | \(n.title)")
        }
        if notes.isEmpty { lines.append("- none") }
        return lines.prefix(maxLines).joined(separator: "\n")
    }
}
