import Foundation
import EventKit

/// RemindersAdapter over EventKit: reminders appear in the Reminders app.
final class EventKitReminders: RemindersAdapter, @unchecked Sendable {
    enum Failure: Error { case accessDenied }

    private let store = EKEventStore()

    func createReminder(title: String, due: Date) async throws -> String {
        guard try await store.requestFullAccessToReminders() else { throw Failure.accessDenied }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func deleteReminder(identifier: String) async throws {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }
}
