import Foundation

/// Compact view of the graph for the prompt: open tasks and recent notes, capped in size.
/// This is the only graph content sent with a request, so the cloud never sees the whole graph.
public enum Digest {
    public static func build(_ snap: GraphSnapshot, maxLines: Int = 40) -> String {
        let openTasks = snap.nodes.values
            .filter { $0.className == "Task" && ["proposed", "active"].contains($0.status) }
            .sorted { ($0.props["due"]?.stringValue ?? "~") < ($1.props["due"]?.stringValue ?? "~") }
        let notes = snap.nodes.values
            .filter { $0.className == "Note" && $0.status != "dropped" }
            .sorted { ($0.props["created_at"]?.stringValue ?? "") > ($1.props["created_at"]?.stringValue ?? "") }

        var lines: [String] = []
        lines.append("Open tasks:")
        for t in openTasks.prefix(maxLines / 2) {
            let due = t.props["due"]?.stringValue.map { " due \($0)" } ?? ""
            lines.append("- Task \(t.id) | \(t.title) |\(due) status \(t.status)")
        }
        if openTasks.isEmpty { lines.append("- none") }
        lines.append("Recent notes:")
        for n in notes.prefix(maxLines / 2) {
            lines.append("- Note \(n.id) | \(n.title)")
        }
        if notes.isEmpty { lines.append("- none") }
        return lines.prefix(maxLines).joined(separator: "\n")
    }
}
