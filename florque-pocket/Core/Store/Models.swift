import Foundation
import SwiftData

// Purpose: the app's data model. A `Note` is something the user shared; a `PocketTask` is something the user
// wants to do, with an optional due time and reminder. These SwiftData objects are the only storage: workflows
// read and write them through `PocketStore`, and there is no schema file or generic graph layer.
//
// Testing: `PocketStoreTests` writes and reads these objects on an in-memory container and checks each field.

/// Lifecycle of a note or task. A dropped item stays in the store but is left out of answers and the digest.
public enum ItemStatus: String, Codable, Sendable, Equatable {
    case active
    case dropped
}

/// A saved statement or idea, stored as the user wrote it.
@Model
public final class Note {
    @Attribute(.unique) public var id: String
    public var title: String
    public var body: String
    /// Stored as its raw value; use `status` in code.
    public var statusRaw: String
    public var createdAt: Date
    public var updatedAt: Date

    public var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    public init(id: String, title: String, body: String, status: ItemStatus, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Something the user wants to do. `due` is set only when the user gave a day and a time.
@Model
public final class PocketTask {
    @Attribute(.unique) public var id: String
    public var title: String
    /// Stored as its raw value; use `status` in code.
    public var statusRaw: String
    public var due: Date?
    /// Identifier of the reminder created for this task, once it exists.
    public var eventId: String?
    /// Id of the note this task came from, when there is one.
    public var about: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    public init(id: String, title: String, status: ItemStatus, due: Date?, eventId: String?, about: String?,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.statusRaw = status.rawValue
        self.due = due
        self.eventId = eventId
        self.about = about
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Value copies for crossing actor boundaries

/// A copy of a `Note`. SwiftData objects stay inside `PocketStore`; callers get these.
public struct NoteRecord: Sendable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let status: ItemStatus
    public let createdAt: Date
    public let updatedAt: Date

    init(_ note: Note) {
        id = note.id; title = note.title; body = note.body; status = note.status
        createdAt = note.createdAt; updatedAt = note.updatedAt
    }
}

/// A copy of a `PocketTask`.
public struct TaskRecord: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: ItemStatus
    public let due: Date?
    public let eventId: String?
    public let about: String?
    public let createdAt: Date
    public let updatedAt: Date

    init(_ task: PocketTask) {
        id = task.id; title = task.title; status = task.status; due = task.due; eventId = task.eventId
        about = task.about; createdAt = task.createdAt; updatedAt = task.updatedAt
    }
}

/// Which kind of item a search or a tool result is about.
public enum ItemKind: String, Sendable, Equatable {
    case note = "Note"
    case task = "Task"
}

/// One item found by a search: either a note or a task.
public enum StoredItem: Sendable, Equatable {
    case note(NoteRecord)
    case task(TaskRecord)

    public var id: String {
        switch self {
        case .note(let n): n.id
        case .task(let t): t.id
        }
    }

    public var kind: ItemKind {
        switch self {
        case .note: .note
        case .task: .task
        }
    }

    public var title: String {
        switch self {
        case .note(let n): n.title
        case .task(let t): t.title
        }
    }

    public var updatedAt: Date {
        switch self {
        case .note(let n): n.updatedAt
        case .task(let t): t.updatedAt
        }
    }
}
