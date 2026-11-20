import Foundation
import Yams

// MARK: - Resolved model

public struct OntologyEnum: Sendable {
    public let name: String
    public let values: [String]                 // permissible values, in file order
    public let descriptions: [String: String]
}

public struct SlotDef: Sendable {
    public let name: String
    public let range: String                    // class, enum or primitive name
    public let required: Bool
    public let multivalued: Bool
    public let isEdge: Bool
    public let description: String?
}

public struct ClassDef: Sendable {
    public let name: String
    public let parent: String?
    public let isAbstract: Bool
    public let description: String?
    public let useWhen: String?
    public let notFor: String?
    /// Every slot the class accepts, including inherited ones, with slot_usage applied.
    public let slots: [String: SlotDef]
    /// Slot names in declaration order (inherited first), used for stable prompts.
    public let slotOrder: [String]

    public var edgeSlots: [SlotDef] { slotOrder.compactMap { slots[$0] }.filter(\.isEdge) }
    public var valueSlots: [SlotDef] { slotOrder.compactMap { slots[$0] }.filter { !$0.isEdge } }
}

public enum OntologyError: Error, Equatable, CustomStringConvertible {
    case parse(String)
    case unknownParent(cls: String, parent: String)
    case cycle(String)

    public var description: String {
        switch self {
        case .parse(let m): "Ontology YAML could not be parsed: \(m)"
        case .unknownParent(let c, let p): "Class \(c) inherits from unknown class \(p)"
        case .cycle(let c): "Inheritance cycle at \(c)"
        }
    }
}

/// A LinkML-style ontology loaded at runtime. Schema changes are edits to the YAML, not code.
public struct Ontology: Sendable {
    public let name: String
    public let description: String
    public let enums: [String: OntologyEnum]
    public let classes: [String: ClassDef]

    public static let primitiveRanges: Set<String> = ["string", "integer", "float", "double", "boolean", "date", "datetime", "uri"]

    public func classDef(_ name: String) -> ClassDef? { classes[name] }

    /// True when `child` is `ancestor` or inherits from it.
    public func isA(_ child: String, _ ancestor: String) -> Bool {
        var current: String? = child
        var guardCount = 0
        while let c = current, guardCount < 64 {
            if c == ancestor { return true }
            current = classes[c]?.parent
            guardCount += 1
        }
        return false
    }

    /// Concrete classes that may be created, in name order.
    public var concreteClassNames: [String] {
        classes.values.filter { !$0.isAbstract }.map(\.name).sorted()
    }

    public static func load(yaml: String) throws -> Ontology {
        let raw: RawOntology
        do { raw = try YAMLDecoder().decode(RawOntology.self, from: yaml) }
        catch { throw OntologyError.parse(String(describing: error)) }
        return try build(raw)
    }

    static func build(_ raw: RawOntology) throws -> Ontology {
        var enums: [String: OntologyEnum] = [:]
        for (name, e) in raw.enums ?? [:] {
            let names = (e.permissible_values ?? [:]).keys.sorted()
            enums[name] = OntologyEnum(name: name, values: names,
                                       descriptions: (e.permissible_values ?? [:]).compactMapValues { $0.description })
        }
        let globalSlots = raw.slots ?? [:]
        let rawClasses = raw.classes ?? [:]

        func slotDef(_ name: String) -> SlotDef {
            let s = globalSlots[name]
            let isEdge = s?.annotations?["edge"]?.boolValue == true
            return SlotDef(name: name, range: s?.range ?? "string", required: s?.required ?? false,
                           multivalued: s?.multivalued ?? false, isEdge: isEdge, description: s?.description)
        }

        var resolved: [String: ClassDef] = [:]
        func resolve(_ name: String, stack: [String]) throws -> ClassDef {
            if let done = resolved[name] { return done }
            if stack.contains(name) { throw OntologyError.cycle(name) }
            guard let rc = rawClasses[name] else { throw OntologyError.unknownParent(cls: stack.last ?? name, parent: name) }

            var slots: [String: SlotDef] = [:]
            var order: [String] = []
            if let p = rc.is_a {
                guard rawClasses[p] != nil else { throw OntologyError.unknownParent(cls: name, parent: p) }
                let parent = try resolve(p, stack: stack + [name])
                slots = parent.slots
                order = parent.slotOrder
            }
            for slotName in rc.slots ?? [] {
                if !order.contains(slotName) { order.append(slotName) }
                slots[slotName] = slotDef(slotName)
            }
            for (slotName, usage) in rc.slot_usage ?? [:] {
                guard let base = slots[slotName] else { continue }
                slots[slotName] = SlotDef(name: base.name, range: usage.range ?? base.range,
                                          required: usage.required ?? base.required,
                                          multivalued: base.multivalued, isEdge: base.isEdge,
                                          description: base.description)
            }
            let def = ClassDef(name: name, parent: rc.is_a, isAbstract: rc.abstract ?? false,
                               description: rc.description,
                               useWhen: rc.annotations?["use_when"]?.stringValue,
                               notFor: rc.annotations?["not_for"]?.stringValue,
                               slots: slots, slotOrder: order)
            resolved[name] = def
            return def
        }
        for name in rawClasses.keys.sorted() { _ = try resolve(name, stack: []) }

        return Ontology(name: raw.name ?? "ontology", description: raw.description ?? "",
                        enums: enums, classes: resolved)
    }
}

// MARK: - Raw YAML shapes (LinkML subset)

struct RawOntology: Decodable {
    let name: String?
    let description: String?
    let enums: [String: RawEnum]?
    let slots: [String: RawSlot]?
    let classes: [String: RawClass]?
}

struct RawEnum: Decodable {
    let permissible_values: [String: RawPermissibleValue]?
}

private enum DescriptionKey: String, CodingKey { case description }

struct RawPermissibleValue: Decodable {
    let description: String?
    init(from decoder: Decoder) throws {
        // Tolerates `value: null` as well as `value: {description: ...}`.
        let c = try? decoder.container(keyedBy: DescriptionKey.self)
        description = try? c?.decodeIfPresent(String.self, forKey: .description)
    }
}

struct RawSlot: Decodable {
    let range: String?
    let required: Bool?
    let multivalued: Bool?
    let description: String?
    let annotations: [String: JSONValue]?
}

struct RawClass: Decodable {
    let is_a: String?
    let abstract: Bool?
    let description: String?
    let annotations: [String: JSONValue]?
    let slots: [String]?
    let slot_usage: [String: RawSlotUsage]?
}

struct RawSlotUsage: Decodable {
    let required: Bool?
    let range: String?
}
