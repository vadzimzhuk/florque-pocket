import Foundation

/// Turns an ontology into model-facing text, so prompts follow the YAML without code changes.
public enum PromptCompiler {
    /// Describes every concrete type, its fields and links, and the enum values.
    public static func ontologyGuide(_ ont: Ontology) -> String {
        var lines: [String] = ["Types:"]
        for name in ont.concreteClassNames {
            guard let cls = ont.classDef(name) else { continue }
            var head = "- \(name)"
            if let use = cls.useWhen { head += ": use when \(use)" }
            if let not = cls.notFor { head += " Not for: \(not)" }
            lines.append(head)
            for slot in cls.valueSlots {
                var line = "    \(slot.name): \(describeRange(ont, slot))"
                if slot.required { line += " (required)" }
                if let d = slot.description { line += " - \(d)" }
                lines.append(line)
            }
            for slot in cls.edgeSlots {
                let many = slot.multivalued ? "list of ids" : "id"
                lines.append("    link \(slot.name) -> \(slot.range) (\(many))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Tool contract shown to the model. Reply is one JSON object.
    public static func toolContract() -> String {
        """
        Reply with one JSON object and nothing else:
        {"calls":[{"tool":"remember","args":{"type":"<Type>","id":"<optional id to update>","<field>":"<value>","<link>":"<id or list of ids>"}}],"say":"<short reply to the user>"}
        Tools:
        - remember: create or update a node. args: type, id (optional), fields, links.
        - link: args {"from": id, "link": name, "to": id}
        - unlink: same args as link
        - set_status: args {"id": id, "status": value}
        - recall: args {"type": optional, "text": optional, "limit": optional number}
        - due: args {"before": ISO date-time}
        Use at most 5 calls. Do not invent ids; use ids returned by recall or created earlier in this reply.
        """
    }

    private static func describeRange(_ ont: Ontology, _ slot: SlotDef) -> String {
        if let e = ont.enums[slot.range] { return "one of \(e.values.joined(separator: "|"))" }
        return slot.range
    }
}
