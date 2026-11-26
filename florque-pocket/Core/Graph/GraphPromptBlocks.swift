import Foundation

// Purpose: builds the "allowed node types" and "allowed link types" blocks for extraction prompts (brief 6.2 and 7).
// Only enabled types appear. An edge type appears only when every node type it names is enabled, so a disabled
// type takes its links out of the prompt too. When there are more types than fit, types whose key or name appears
// in the user's message come first. Lines are added whole until the budget is used; a line is never cut in half.
//
// Testing: `GraphPromptBlocksTests` checks exact output for the default and a custom configuration, that disabled
// types disappear, the per-prompt caps, and the character budget.

public nonisolated enum GraphPromptBlocks {
    /// Token budget for each block (brief section 7), converted with the same 2.5 characters per token as the CER budget.
    public static let typeBlockTokens = 300
    public static let charsPerToken = 2.5
    public static var typeBlockChars: Int { Int(Double(typeBlockTokens) * charsPerToken) }
    public static let maxNodeTypes = 12
    public static let maxEdgeTypes = 10

    /// Lines like `- person: Someone in the user's life, mentioned by name`.
    public static func nodeTypesBlock(_ types: [NodeTypeRecord], message: String? = nil) -> String {
        let enabled = types.filter(\.enabled)
        let ordered = prioritised(enabled, message: message) { [$0.key, $0.name] }
        let lines = ordered.prefix(maxNodeTypes).map { "- \($0.key): \($0.typeDescription)" }
        return fitted(lines)
    }

    /// Lines like `- participates (person → event): A person takes part in an event`. An edge type is included only
    /// when each node type it names is enabled.
    public static func edgeTypesBlock(_ edges: [EdgeTypeRecord], nodeTypes: [NodeTypeRecord],
                                      message: String? = nil) -> String {
        let enabledNodes = Set(nodeTypes.filter(\.enabled).map(\.key))
        let usable = edges.filter { edge in
            edge.enabled
                && edge.fromNodeKeys.allSatisfy(enabledNodes.contains)
                && edge.toNodeKeys.allSatisfy(enabledNodes.contains)
        }
        let ordered = prioritised(usable, message: message) { [$0.key, $0.name] }
        let lines = ordered.prefix(maxEdgeTypes).map { edge -> String in
            let ends = edge.symmetric ? "symmetric" : "\(endpoints(edge.fromNodeKeys)) → \(endpoints(edge.toNodeKeys))"
            return "- \(edge.key) (\(ends)): \(edge.typeDescription)"
        }
        return fitted(lines)
    }

    // MARK: helpers

    /// Items whose key or name appears in `message` first, then the rest, each group in its stored order.
    static func prioritised<T>(_ items: [T], message: String?, names: (T) -> [String]) -> [T] {
        guard let message, !message.isEmpty else { return items }
        let text = message.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func matched(_ item: T) -> Bool {
            names(item).contains { name in
                !name.isEmpty && text.contains(name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                             locale: nil))
            }
        }
        return items.filter(matched) + items.filter { !matched($0) }
    }

    static func endpoints(_ keys: [String]) -> String {
        keys.isEmpty ? "any" : keys.joined(separator: "|")
    }

    /// Joins whole lines until the next one would exceed the budget.
    static func fitted(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            let next = out.isEmpty ? line : out + "\n" + line
            guard next.count <= typeBlockChars else { break }
            out = next
        }
        return out
    }
}
