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
- Column (id, name) - e.g. Backlog=1, Ready=2, Doing=3, Done=4
- Task (id, title, description, color_id, column_id, position)

iOS Models mirror this: BoardColumn { id, name, tasks: [BoardTask] }

Mapping to Apple Reminders:
- Each Kanboard column_id maps to an EKCalendar (Reminders List) via columnMap
- Matching via note field: "kb_id:123" stored in EKReminder.notes
- Move detection: If EKReminder.calendar.title changes, reverseMap gives new column_id -> call moveTaskPosition
- Complete detection: EKReminder.isCompleted == true -> closeTask

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
- Drag & Drop: onDrag stores task, onDrop triggers move
- Settings sheet: URL + Token + Project ID (AppStorage)

## Sync Flow
1. On launch/load: getBoard -> update UI -> ensure Reminders lists exist -> syncFromKanboard (create/update reminders)
2. On user drag in UI: moveTaskPosition API -> reload -> syncFromKanboard
3. On EKEventStoreChanged: checkForChangesFromReminders -> closeTask or moveTaskPosition -> reload

## Constraints
- Must work without Mac server (pure on-device EventKit)
- No CoreData, keep simple
- Handle offline: API calls can fail, keep local columns as source of truth until reload
- Privacy: Need NSRemindersUsageDescription in Info.plist

## Future Mods for LLM
- Add swimlanes: getBoard returns swimlanes
- Add task detail: call getTask(task_id)
- Add WIP limits: column has task_limit
- Add color dots: task.color_id -> color map
- Replace polling with BGAppRefreshTask for background sync

## Files
- KanboardClient.swift: networking
- BoardViewModel.swift: state + load/move
- EventKitSyncService.swift: Reminders bridge
- ContentView.swift: UI
- DESIGN.md: this file
