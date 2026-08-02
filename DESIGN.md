# Project: SimpleKanboard - Kanboard iOS Client Clone

## Intent
Clone the App Store app "Simple Kanban Board" (id1670749530) look and feel, but connect it to a self-hosted Kanboard instance (kanboard.org) on Linux. The user has iPhone + Mac + Linux server. They want native iOS Kanban with optional sync to Apple Reminders.

The original app is closed source, offline-only, local storage. This clone replaces local storage with Kanboard JSON-RPC API.

## Architecture
- iOS App: SwiftUI, iOS 17+
- Backend: Self-hosted Kanboard PHP app, exposes /jsonrpc.php
- Auth: Basic Auth header: username=jsonrpc, password=API_TOKEN (from Kanboard profile)
- Apple Integration: EventKit for Reminders, optional 2-way sync

## Data Model
Kanboard Concepts:
- Project (id)
- Swimlane (id) - getBoard nests columns inside swimlanes
- Column (id, title) - ids are unique per Kanboard instance, NOT per project, so never hardcode them
- Task (id, title, description, color_id, column_id, swimlane_id, position)

iOS Models mirror this: BoardColumn { id, name, tasks: [BoardTask] }, BoardTask { id, title, swimlaneId }
getBoard parsing flattens swimlane -> columns -> tasks, merging the same column id across swimlanes.

Mapping to Apple Reminders:
- Each column maps to an EKCalendar (Reminders List) named "KB - <column title>", derived from the
  live board on every sync (columnIdByListName), not from a fixed table
- Matching via note field: "kb_id:123" stored in EKReminder.notes
- Move detection: EKReminder.calendar.title differs from the list recorded at the last sync
  -> columnIdByListName gives the new column_id -> moveTaskPosition
- Complete detection: EKReminder.isCompleted == true and not yet closed -> closeTask
- Change detection is diff-based: EKEventStoreChanged fires for any Reminders edit, so only
  reminders that actually changed since the last sync produce API writes

## API Calls Used
- getBoard(project_id) -> returns columns with nested tasks
- moveTaskPosition(project_id, task_id, column_id, position)
- createTask(project_id, title, column_id)
- closeTask(task_id)

## UI Design (Must match Simple Kanban Board)
- Horizontal ScrollView containing columns
- Column: 300pt wide, light gray bg #F2F2F7, rounded 16, title top left semibold rounded font
- Card: white bg, 10 corner radius, subtle shadow, padding 12, title rounded font body
- Add card button at bottom of each column
- Drag & Drop: onDrag carries the task id as its payload, onDrop reads the payload and moves that task
- Settings sheet: URL + Project ID (AppStorage) + Token (Keychain, SecureField)
- Errors surface in an alert driven by BoardViewModel.errorMessage; nothing is silently swallowed

## Sync Flow
1. On launch/load: getBoard -> update UI -> ensure Reminders lists exist -> syncFromKanboard
   (create/update reminders, delete reminders whose task left the board, record list snapshot)
2. On user drag in UI: moveTaskPosition API -> reload -> syncFromKanboard
3. On EKEventStoreChanged: pendingChanges() diffs against the snapshot -> closeTask or
   moveTaskPosition for the changed reminders only -> reload

## Constraints
- Must work without Mac server (pure on-device EventKit)
- No CoreData, keep simple
- Handle offline: API calls can fail, keep local columns as source of truth until reload
- Privacy: iOS 17 requestFullAccessToReminders() requires NSRemindersFullAccessUsageDescription
  in Info.plist (the legacy NSRemindersUsageDescription key is not enough and the app is
  terminated on first request without it)
- Secrets: API token lives in the Keychain (KeychainTokenStore), never UserDefaults

## Future Mods for LLM
- Add swimlanes: getBoard returns swimlanes
- Add task detail: call getTask(task_id)
- Add WIP limits: column has task_limit
- Add color dots: task.color_id -> color map
- Replace polling with BGAppRefreshTask for background sync

## Files
- KanboardClient.swift: networking + KanboardError
- BoardViewModel.swift: state, board parsing, load/move/add
- EventKitSyncService.swift: Reminders bridge
- KeychainTokenStore.swift: API token storage
- ContentView.swift: UI
- DESIGN.md: this file

## Not Yet In Repo
- No .xcodeproj/.xcworkspace and no Info.plist, so there is no buildable target yet.
  The privacy key above must be added when the project is created.
