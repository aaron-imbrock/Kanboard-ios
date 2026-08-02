import EventKit
import Foundation

private let kanboardNotePrefix = "kb_id:"

/// Reads the Kanboard task id out of a reminder's notes. File-scope and nonisolated so it
/// can run inside EventKit's fetch callback.
private func parseTaskId(_ notes: String) -> Int? {
    guard let range = notes.range(of: kanboardNotePrefix) else { return nil }
    return Int(notes[range.upperBound...].prefix(while: { $0.isNumber }))
}

/// A `Sendable` projection of an `EKReminder`. EventKit objects are not `Sendable`, so the
/// fetch callback converts to this before crossing back to the main actor; every mutation of
/// a real `EKReminder` then happens on the main actor via `reminder(withIdentifier:)`.
private struct ReminderSnapshot: Sendable {
    let itemIdentifier: String
    let taskId: Int
    let title: String
    let calendarTitle: String
    let calendarIdentifier: String
    let isCompleted: Bool

    init?(_ reminder: EKReminder) {
        guard let notes = reminder.notes,
              let taskId = parseTaskId(notes),
              let title = reminder.title,
              let calendar = reminder.calendar else { return nil }
        self.itemIdentifier = reminder.calendarItemIdentifier
        self.taskId = taskId
        self.title = title
        self.calendarTitle = calendar.title
        self.calendarIdentifier = calendar.calendarIdentifier
        self.isCompleted = reminder.isCompleted
    }
}

/// Bridges the board to Apple Reminders: one Reminders list per Kanboard column,
/// each reminder tagged with `kb_id:<task id>` in its notes.
@MainActor
final class EventKitSyncService {
    enum SyncError: LocalizedError {
        case noRemindersSource

        var errorDescription: String? {
            switch self {
            case .noRemindersSource:
                return "No Reminders account is available to create the Kanboard lists in."
            }
        }
    }

    /// A change the user made in Reminders that has not been sent to Kanboard yet.
    enum ReminderChange: Equatable {
        case completed(taskId: Int)
        case moved(taskId: Int, columnId: Int)
    }

    private let store = EKEventStore()
    /// Built from the live board on every sync — column ids are unique per Kanboard
    /// instance, so they cannot be hardcoded.
    private var columnIdByListName: [String: Int] = [:]
    private var lastListName: [Int: String] = [:]
    private var closedTaskIds: Set<Int> = []

    static func listName(for columnName: String) -> String { "KB - \(columnName)" }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    /// Makes Reminders match the board: creates missing reminders, moves/renames existing
    /// ones, and removes reminders whose task is no longer on the board.
    func syncFromKanboard(columns: [BoardViewModel.BoardColumn]) async throws {
        var map: [String: Int] = [:]
        for column in columns {
            let name = Self.listName(for: column.name)
            if map[name] == nil { map[name] = column.id }
        }
        columnIdByListName = map
        guard !map.isEmpty else { return }

        let calendars = try ensureLists(named: Array(map.keys))
        let snapshots = await fetchSnapshots(in: Array(calendars.values))
        let boardTaskIds = Set(columns.flatMap { $0.tasks.map(\.id) })

        var snapshotByTaskId: [Int: ReminderSnapshot] = [:]
        var staleIdentifiers: [String] = []
        for snapshot in snapshots {
            if boardTaskIds.contains(snapshot.taskId), snapshotByTaskId[snapshot.taskId] == nil {
                snapshotByTaskId[snapshot.taskId] = snapshot
            } else {
                // The task was deleted or closed in Kanboard, or is a duplicate tag.
                staleIdentifiers.append(snapshot.itemIdentifier)
            }
        }
        for identifier in staleIdentifiers {
            guard let reminder = reminder(withIdentifier: identifier) else { continue }
            try store.remove(reminder, commit: false)
        }

        var state: [Int: String] = [:]
        for column in columns {
            guard let calendar = calendars[Self.listName(for: column.name)] else { continue }
            for task in column.tasks {
                if let snapshot = snapshotByTaskId[task.id] {
                    if snapshot.calendarIdentifier != calendar.calendarIdentifier || snapshot.title != task.title,
                       let reminder = reminder(withIdentifier: snapshot.itemIdentifier) {
                        reminder.calendar = calendar
                        reminder.title = task.title
                        try store.save(reminder, commit: false)
                    }
                } else {
                    let reminder = EKReminder(eventStore: store)
                    reminder.title = task.title
                    reminder.notes = kanboardNotePrefix + "\(task.id)"
                    reminder.calendar = calendar
                    try store.save(reminder, commit: false)
                }
                state[task.id] = calendar.title
            }
        }
        try store.commit()

        lastListName = state
        closedTaskIds.formIntersection(boardTaskIds)
    }

    /// Diffs Reminders against the state recorded by the last sync and returns only what
    /// actually changed, so an unrelated Reminders edit produces no board writes.
    func pendingChanges() async -> [ReminderChange] {
        let names = Set(columnIdByListName.keys)
        guard !names.isEmpty else { return [] }
        let calendars = store.calendars(for: .reminder).filter { names.contains($0.title) }
        guard !calendars.isEmpty else { return [] }

        var changes: [ReminderChange] = []
        for snapshot in await fetchSnapshots(in: calendars) {
            let taskId = snapshot.taskId
            let listName = snapshot.calendarTitle

            if snapshot.isCompleted {
                if !closedTaskIds.contains(taskId) {
                    closedTaskIds.insert(taskId)
                    changes.append(.completed(taskId: taskId))
                }
                lastListName[taskId] = listName
                continue
            }

            closedTaskIds.remove(taskId)
            defer { lastListName[taskId] = listName }
            // A reminder we have never seen is adopted silently rather than treated as a move.
            guard let previous = lastListName[taskId], previous != listName else { continue }
            guard let columnId = columnIdByListName[listName] else { continue }
            changes.append(.moved(taskId: taskId, columnId: columnId))
        }
        return changes
    }

    private func ensureLists(named names: [String]) throws -> [String: EKCalendar] {
        var calendars: [String: EKCalendar] = [:]
        let wanted = Set(names)
        for calendar in store.calendars(for: .reminder) where wanted.contains(calendar.title) {
            if calendars[calendar.title] == nil { calendars[calendar.title] = calendar }
        }

        let missing = names.filter { calendars[$0] == nil }
        guard !missing.isEmpty else { return calendars }
        guard let source = store.defaultCalendarForNewReminders()?.source else {
            throw SyncError.noRemindersSource
        }
        for name in missing {
            let calendar = EKCalendar(for: .reminder, eventStore: store)
            calendar.title = name
            calendar.source = source
            try store.saveCalendar(calendar, commit: true)
            calendars[name] = calendar
        }
        return calendars
    }

    /// EventKit has no async `fetchReminders`; it is callback-only. Only `ReminderSnapshot`
    /// values cross the continuation, so no non-`Sendable` EventKit object changes isolation.
    private func fetchSnapshots(in calendars: [EKCalendar]) async -> [ReminderSnapshot] {
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap { ReminderSnapshot($0) })
            }
        }
    }

    private func reminder(withIdentifier identifier: String) -> EKReminder? {
        store.calendarItem(withIdentifier: identifier) as? EKReminder
    }
}
