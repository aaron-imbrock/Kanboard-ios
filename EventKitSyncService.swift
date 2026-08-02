import EventKit

final class EventKitSyncService {
    let store = EKEventStore()
    let columnMap: [Int:String] = [1:"KB - Backlog", 2:"KB - Ready", 3:"KB - In Progress", 4:"KB - Done"]
    var reverseMap: [String:Int] { Dictionary(uniqueKeysWithValues: columnMap.map { ($1, $0) }) }

    func requestAccess() async -> Bool {
        do { return try await store.requestFullAccessToReminders() } catch { return false }
    }
    func ensureListsExist() {
        let existing = Set(store.calendars(for:.reminder).map { $0.title })
        for name in columnMap.values where!existing.contains(name) {
            let cal = EKCalendar(for:.reminder, eventStore: store)
            cal.title = name; cal.source = store.defaultCalendarForNewReminders()?.source
            try? store.saveCalendar(cal, commit: true)
        }
    }
    func syncFromKanboard(columns: [BoardViewModel.BoardColumn]) {
        let allCals = store.calendars(for:.reminder)
        let targetCals = allCals.filter { columnMap.values.contains($0.title) }
        let pred = store.predicateForReminders(in: targetCals)
        store.fetchReminders(matching: pred) { reminders in
            guard let reminders = reminders else { return }
            var byKbId: [Int:EKReminder] = [:]
            for r in reminders {
                if let notes = r.notes, let id = self.parseKbId(notes) { byKbId[id] = r }
            }
            for col in columns {
                guard let cal = allCals.first(where: { $0.title == self.columnMap[col.id] }) else { continue }
                for task in col.tasks {
                    if let existing = byKbId[task.id] {
                        if existing.calendar.title!= cal.title || existing.title!= task.title {
                            existing.calendar = cal; existing.title = task.title
                            try? self.store.save(existing, commit: true)
                        }
                    } else {
                        let rem = EKReminder(eventStore: self.store)
                        rem.title = task.title; rem.notes = "kb_id:\(task.id)"; rem.calendar = cal
                        try? self.store.save(rem, commit: true)
                    }
                }
            }
        }
    }
    func checkForChangesFromReminders(client: KanboardClient, projectId: Int) async {
        let cals = store.calendars(for:.reminder).filter { columnMap.values.contains($0.title) }
        let pred = store.predicateForReminders(in: cals)
        guard let reminders = try? await store.reminders(matching: pred) else { return }
        for rem in reminders {
            guard let notes = rem.notes, let kbId = parseKbId(notes) else { continue }
            if rem.isCompleted { _ = try? await client.rpc(method: "closeTask", params: ["task_id": kbId]); continue }
            if let newColId = reverseMap[rem.calendar.title] {
                _ = try? await client.rpc(method: "moveTaskPosition", params: ["project_id":projectId,"task_id":kbId,"column_id":newColId,"position":1])
            }
        }
    }
    private func parseKbId(_ notes: String) -> Int? {
        guard let range = notes.range(of: "kb_id:") else { return nil }
        return Int(notes[range.upperBound...].prefix(while: { $0.isNumber }))
    }
}
