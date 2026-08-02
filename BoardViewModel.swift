import Combine
import Foundation

@MainActor
final class BoardViewModel: ObservableObject {
    struct BoardColumn: Identifiable, Equatable {
        let id: Int
        var name: String
        var tasks: [BoardTask]
    }

    struct BoardTask: Identifiable, Equatable {
        let id: Int
        var title: String
        var swimlaneId: Int?
    }

    @Published private(set) var columns: [BoardColumn] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private(set) var projectId = 1
    private var client: KanboardClient?
    private let reminderSync = EventKitSyncService()
    private var remindersEnabled = false
    private var isApplyingReminderChanges = false

    var isConfigured: Bool { client != nil }

    func configure(baseURL: String, token: String, projectId: Int) {
        self.client = KanboardClient(baseURL: baseURL, token: token)
        self.projectId = projectId
    }

    func load() async {
        guard let client else {
            errorMessage = "Add your Kanboard server URL and API token in Settings."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let swimlanes = try await client.getBoard(projectId: projectId)
            columns = makeColumns(from: swimlanes)
        } catch {
            report(error)
            return
        }
        await syncReminders()
    }

    func move(task: BoardTask, to columnId: Int) async {
        guard let client else { return }
        do {
            try await client.moveTask(projectId: projectId, taskId: task.id, columnId: columnId, swimlaneId: task.swimlaneId)
        } catch {
            report(error)
        }
        await load()
    }

    func addTask(title: String, to columnId: Int) async {
        guard let client else { return }
        do {
            try await client.createTask(projectId: projectId, title: title, columnId: columnId)
        } catch {
            report(error)
        }
        await load()
    }

    /// Pushes edits the user made in Reminders back to Kanboard. Only genuine changes
    /// since the last sync are sent, so an unrelated Reminders edit does not touch the board.
    func handleReminderChange() async {
        guard remindersEnabled, let client, !isApplyingReminderChanges else { return }
        isApplyingReminderChanges = true
        defer { isApplyingReminderChanges = false }

        let changes = await reminderSync.pendingChanges()
        guard !changes.isEmpty else { return }
        do {
            for change in changes {
                switch change {
                case .completed(let taskId):
                    try await client.closeTask(taskId: taskId)
                case .moved(let taskId, let columnId):
                    try await client.moveTask(projectId: projectId,
                                              taskId: taskId,
                                              columnId: columnId,
                                              swimlaneId: task(withId: taskId)?.task.swimlaneId)
                }
            }
        } catch {
            report(error)
        }
        await load()
    }

    func task(withId id: Int) -> (task: BoardTask, columnId: Int)? {
        for column in columns {
            if let match = column.tasks.first(where: { $0.id == id }) {
                return (match, column.id)
            }
        }
        return nil
    }

    private func syncReminders() async {
        do {
            guard try await reminderSync.requestAccess() else {
                remindersEnabled = false
                return
            }
            remindersEnabled = true
            try await reminderSync.syncFromKanboard(columns: columns)
        } catch {
            remindersEnabled = false
            errorMessage = "Reminders sync failed: \(message(for: error))"
        }
    }

    /// Flattens `getBoard`'s swimlane → column → task nesting. The same column id appears
    /// once per swimlane, so tasks are merged into a single column in board order.
    private func makeColumns(from swimlanes: [[String: Any]]) -> [BoardColumn] {
        var order: [Int] = []
        var byId: [Int: BoardColumn] = [:]

        for entry in swimlanes {
            let rawColumns: [[String: Any]]
            let swimlaneId: Int?
            if let nested = entry["columns"] as? [[String: Any]] {
                rawColumns = nested
                swimlaneId = Self.intValue(entry["id"])
            } else {
                // Tolerate a flat column list, in case the server omits swimlanes.
                rawColumns = [entry]
                swimlaneId = nil
            }

            for rawColumn in rawColumns {
                guard let columnId = Self.intValue(rawColumn["id"]) else { continue }
                let name = rawColumn["title"] as? String
                    ?? rawColumn["name"] as? String
                    ?? "Column \(columnId)"
                let tasks = (rawColumn["tasks"] as? [[String: Any]] ?? []).compactMap { raw -> BoardTask? in
                    guard let taskId = Self.intValue(raw["id"]), let title = raw["title"] as? String else { return nil }
                    return BoardTask(id: taskId, title: title, swimlaneId: Self.intValue(raw["swimlane_id"]) ?? swimlaneId)
                }
                if byId[columnId] != nil {
                    byId[columnId]?.tasks.append(contentsOf: tasks)
                } else {
                    order.append(columnId)
                    byId[columnId] = BoardColumn(id: columnId, name: name, tasks: tasks)
                }
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// Kanboard sends ids as either JSON numbers or strings depending on the endpoint.
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let string as String: return Int(string)
        case let number as NSNumber: return number.intValue
        default: return nil
        }
    }

    private func report(_ error: Error) {
        errorMessage = message(for: error)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
