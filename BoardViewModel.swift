import Foundation
import EventKit

@MainActor class BoardViewModel: ObservableObject {
    @Published var columns: [BoardColumn] = []
    var client: KanboardClient!
    var projectId = 1
    let reminderSync = EventKitSyncService()

    struct BoardColumn: Identifiable { let id: Int; var name: String; var tasks: [BoardTask] }
    struct BoardTask: Identifiable, Equatable { let id: Int; var title: String }

    func load() async {
        guard let rawCols = try? await client.getBoard(projectId: projectId) else { return }
        var newCols: [BoardColumn] = []
        for col in rawCols {
            guard let colId = Int("\(col["id"]?? 0)"),
                  let name = col["name"] as? String else { continue }
            let rawTasks = (col["tasks"] as? [[String:Any]])?? []
            let tasks = rawTasks.compactMap { t -> BoardTask? in
                guard let id = Int("\(t["id"]?? 0)"), let title = t["title"] as? String else { return nil }
                return BoardTask(id: id, title: title)
            }
            newCols.append(BoardColumn(id: colId, name: name, tasks: tasks))
        }
        self.columns = newCols
        if await reminderSync.requestAccess() {
            reminderSync.ensureListsExist()
            reminderSync.syncFromKanboard(columns: newCols)
        }
    }

    func move(task: BoardTask, to columnId: Int) async {
        try? await client.moveTask(projectId: projectId, taskId: task.id, columnId: columnId)
        await load()
    }
}
