import Foundation
import SwiftData

// Purpose: the only access to the app's data. Every read returns value copies (`NoteRecord`, `TaskRecord`), and
// every write changes the SwiftData objects in one `ModelContext` and saves once. A failed save rolls the
// context back, so a batch either lands in full or not at all.
//
// Testing: `PocketStoreTests` runs each operation on an in-memory container, including a failed batch that must
// leave nothing behind, and a file-backed store that must still hold its items after it is reopened.

public enum PocketStoreError: Error, Equatable {
    case unknownNote(String)
    case unknownTask(String)
}

/// One task to create. The id is chosen by the caller so the reply can refer to it.
public struct NewTask: Sendable, Equatable {
    public let id: String
    public let title: String
    public let due: Date?
    public let about: String?

    public init(id: String, title: String, due: Date?, about: String?) {
        self.id = id; self.title = title; self.due = due; self.about = about
    }
}

@ModelActor
public actor PocketStore {
    /// A file-backed container for the app. Items persist across launches.
    public static func fileContainer(url: URL) throws -> ModelContainer {
        try ModelContainer(for: Note.self, PocketTask.self, configurations: ModelConfiguration(url: url))
    }

    /// An in-memory container for tests and previews. Nothing is kept after it is released.
    public static func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: Note.self, PocketTask.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    // MARK: reads

    public func note(id: String) throws -> NoteRecord? {
        try fetchNote(id).map(NoteRecord.init)
    }

    public func task(id: String) throws -> TaskRecord? {
        try fetchTask(id).map(TaskRecord.init)
    }

    /// Active notes, newest first.
    public func recentNotes(limit: Int) throws -> [NoteRecord] {
        try modelContext.fetch(FetchDescriptor<Note>())
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map(NoteRecord.init)
    }

    /// Active tasks, earliest due first; tasks without a due time come last.
    public func openTasks() throws -> [TaskRecord] {
        try modelContext.fetch(FetchDescriptor<PocketTask>())
            .filter { $0.status == .active }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            .map(TaskRecord.init)
    }

    /// Active notes and tasks whose title (or a note's body) contains `text`, most recently updated first.
    /// A nil `text` matches everything; a nil `kind` searches both kinds.
    public func search(text: String?, kind: ItemKind?, limit: Int) throws -> [StoredItem] {
        let needle = text?.lowercased()
        func matches(_ values: String...) -> Bool {
            guard let needle else { return true }
            return values.contains { $0.lowercased().contains(needle) }
        }
        var items: [StoredItem] = []
        if kind != .task {
            for note in try modelContext.fetch(FetchDescriptor<Note>())
            where note.status == .active && matches(note.title, note.body) {
                items.append(.note(NoteRecord(note)))
            }
        }
        if kind != .note {
            for task in try modelContext.fetch(FetchDescriptor<PocketTask>())
            where task.status == .active && matches(task.title) {
                items.append(.task(TaskRecord(task)))
            }
        }
        return Array(items.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// Active tasks due at or before `date`, earliest first.
    public func dueTasks(before date: Date) throws -> [TaskRecord] {
        try openTasks().filter { ($0.due ?? .distantFuture) <= date && $0.due != nil }
    }

    /// Events: active tasks that have a due time. Filters by title text and by the due time's range (both optional),
    /// earliest first.
    public func events(text: String?, from: Date?, to: Date?, limit: Int) throws -> [TaskRecord] {
        let needle = text?.lowercased()
        return try openTasks().filter { task in
            guard let due = task.due else { return false }
            if let from, due < from { return false }
            if let to, due > to { return false }
            guard let needle else { return true }
            return task.title.lowercased().contains(needle)
        }
        .prefix(limit).map { $0 }
    }

    // MARK: writes. Each call is one save.

    /// Saves a note as the user wrote it.
    public func saveNote(id: String, title: String, body: String, now: Date) throws {
        try commit {
            modelContext.insert(Note(id: id, title: title, body: body, status: .active, createdAt: now, updatedAt: now))
        }
    }

    /// Creates tasks as active, all in one save. A task that names a note must name one that exists.
    public func addTasks(_ tasks: [NewTask], now: Date) throws {
        try commit {
            for task in tasks {
                if let about = task.about, try fetchNote(about) == nil {
                    throw PocketStoreError.unknownNote(about)
                }
                modelContext.insert(PocketTask(id: task.id, title: task.title, status: .active, due: task.due,
                                               eventId: nil, about: task.about, createdAt: now, updatedAt: now))
            }
        }
    }

    public func setStatus(_ status: ItemStatus, taskId: String, now: Date) throws {
        try commit {
            guard let task = try fetchTask(taskId) else { throw PocketStoreError.unknownTask(taskId) }
            task.status = status
            task.updatedAt = now
        }
    }

    /// Records the reminder created for a task.
    public func setEventId(_ eventId: String, taskId: String) throws {
        try commit {
            guard let task = try fetchTask(taskId) else { throw PocketStoreError.unknownTask(taskId) }
            task.eventId = eventId
        }
    }

    // MARK: helpers

    /// Runs the changes and saves once. Any throw rolls the context back, so nothing from the batch lands.
    private func commit(_ changes: () throws -> Void) throws {
        do {
            try changes()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func fetchNote(_ id: String) throws -> Note? {
        try modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first
    }

    private func fetchTask(_ id: String) throws -> PocketTask? {
        try modelContext.fetch(FetchDescriptor<PocketTask>(predicate: #Predicate { $0.id == id })).first
    }
}
