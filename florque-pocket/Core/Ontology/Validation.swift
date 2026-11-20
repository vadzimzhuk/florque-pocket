import Foundation

/// Result of checking a node's properties against the ontology.
public struct NodeCheck: Sendable {
    /// Properties with enum values normalised to their permissible spelling.
    public var props: [String: JSONValue]
    public var issues: [String]
}

public enum Validator {
    /// Accepts "2026-11-27", "2026-11-27T09:00", "2026-11-27T09:00:00" and ISO forms with a zone.
    static func isDate(_ s: String) -> Bool { parses(s, "yyyy-MM-dd") }

    static func isDateTime(_ s: String) -> Bool {
        parses(s, "yyyy-MM-dd'T'HH:mm:ss") || parses(s, "yyyy-MM-dd'T'HH:mm")
            || ISO8601DateFormatter().date(from: s) != nil
    }

    private static func parses(_ s: String, _ pattern: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        f.isLenient = false
        return f.date(from: s) != nil
    }

    /// Checks `props` for a node of `className`. With `partial`, only the given props are checked
    /// and required slots are not enforced (used for updates).
    public static func checkNode(_ ont: Ontology, className: String, props: [String: JSONValue],
                                 partial: Bool) -> NodeCheck {
        guard let cls = ont.classDef(className) else {
            return NodeCheck(props: props, issues: ["unknown type \(className)"])
        }
        if cls.isAbstract {
            return NodeCheck(props: props, issues: ["\(className) is abstract; use one of \(ont.concreteClassNames.joined(separator: ", "))"])
        }
        var issues: [String] = []
        var out: [String: JSONValue] = [:]

        for (key, value) in props.sorted(by: { $0.key < $1.key }) {
            guard let slot = cls.slots[key] else {
                issues.append("\(className) has no field \(key)")
                continue
            }
            if slot.isEdge {
                issues.append("\(key) is a link, not a field; use link")
                continue
            }
            if value == .null { out[key] = .null; continue }
            switch checkValue(ont, slot: slot, value: value) {
            case .ok(let v): out[key] = v
            case .problem(let v, let why): out[key] = v; issues.append("\(key): \(why)")
            case .wrongType: issues.append("\(key): expected \(slot.range)")
            }
        }

        if !partial {
            for slot in cls.valueSlots where slot.required {
                let v = out[slot.name]
                if v == nil || v == .null || v?.stringValue == "" {
                    issues.append("\(className) requires \(slot.name)")
                }
            }
        }
        return NodeCheck(props: out, issues: issues)
    }

    /// Checks that `slot` on `fromClass` may point at a node of `toClass`.
    public static func checkLink(_ ont: Ontology, fromClass: String, slot: String, toClass: String) -> [String] {
        guard let cls = ont.classDef(fromClass) else { return ["unknown type \(fromClass)"] }
        guard let def = cls.slots[slot], def.isEdge else {
            return ["\(fromClass) has no link \(slot)"]
        }
        if def.range == "Node" || ont.isA(toClass, def.range) { return [] }
        return ["\(slot) must point at \(def.range), not \(toClass)"]
    }

    private enum ValueCheck {
        case ok(JSONValue)
        case problem(JSONValue, String)
        case wrongType
    }

    private static func checkValue(_ ont: Ontology, slot: SlotDef, value: JSONValue) -> ValueCheck {
        if let e = ont.enums[slot.range] {
            guard let s = value.stringValue else { return .wrongType }
            let wanted = normalise(s)
            if let match = e.values.first(where: { normalise($0) == wanted }) {
                return .ok(.string(match))
            }
            return .problem(value, "must be one of \(e.values.joined(separator: ", "))")
        }
        switch slot.range {
        case "string", "uri":
            return value.stringValue != nil ? .ok(value) : .wrongType
        case "boolean":
            return value.boolValue != nil ? .ok(value) : .wrongType
        case "integer", "float", "double":
            if case .number = value { return .ok(value) }
            return .wrongType
        case "datetime":
            guard let s = value.stringValue else { return .wrongType }
            return isDateTime(s) ? .ok(value)
                : .problem(value, "use ISO date-time, e.g. 2026-11-27T09:00:00")
        case "date":
            guard let s = value.stringValue else { return .wrongType }
            return isDate(s) ? .ok(value) : .problem(value, "use ISO date, e.g. 2026-11-27")
        default:
            return value.stringValue != nil ? .ok(value) : .wrongType
        }
    }

    /// Lenient enum matching: case, spaces and hyphens are ignored ("Key Result" matches key_result).
    public static func normalise(_ s: String) -> String {
        s.lowercased().map { $0 == " " || $0 == "-" ? "_" : $0 }.map(String.init).joined()
    }
}
