import Foundation
import SwiftData

@Model
public final class StoredNode {
    @Attribute(.unique) public var id: String
    public var className: String
    /// Properties as a JSON object. Unknown or new ontology slots live here, so the schema never changes.
    public var propsJSON: String

    public init(id: String, className: String, propsJSON: String) {
        self.id = id
        self.className = className
        self.propsJSON = propsJSON
    }
}

@Model
public final class StoredEdge {
    public var from: String
    public var slot: String
    public var to: String

    public init(from: String, slot: String, to: String) {
        self.from = from
        self.slot = slot
        self.to = to
    }
}
