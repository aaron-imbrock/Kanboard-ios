import SwiftUI
import EventKit

struct ContentView: View {
    @StateObject var vm = BoardViewModel()
    @AppStorage("kb_url") var url = ""
    @AppStorage("kb_token") var token = ""
    @State var showSettings = false
    @State var draggedTask: BoardViewModel.BoardTask?

    var body: some View {
        NavigationView {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment:.top, spacing: 12) {
                    ForEach(vm.columns) { col in
                        VStack(alignment:.leading, spacing: 8) {
                            Text(col.name).font(.system(.subheadline, design:.rounded).weight(.semibold)).padding(8)
                            ForEach(col.tasks) { task in
                                Text(task.title).font(.system(.body, design:.rounded)).padding(12)
                                   .frame(maxWidth:.infinity, alignment:.leading)
                                   .background(Color.white).cornerRadius(10)
                                   .shadow(color:.black.opacity(0.06), radius:3, x:0, y:1)
                                   .onDrag { draggedTask = task; return NSItemProvider(object: "\(task.id)" as NSString) }
                            }
                            Button("+ Add a card") {
                                Task { try? await vm.client.createTask(projectId: vm.projectId, title: "New task", columnId: col.id); await vm.load() }
                            }.font(.caption).foregroundColor(.secondary).padding(8)
                        }
                       .frame(width: 300).background(Color(.systemGroupedBackground)).cornerRadius(16)
                       .onDrop(of: [.text], isTargeted: nil) { _ in if let t = draggedTask { Task { await vm.move(task: t, to: col.id) } }; return true }
                    }
                }.padding()
            }
           .navigationTitle("Board").toolbar { Button("Settings") { showSettings = true } }
        }
       .sheet(isPresented: $showSettings) {
            Form {
                Section("Kanboard Server") {
                    TextField("https://kanboard.example.com", text: $url).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("API Token", text: $token).autocorrectionDisabled()
                }
                Button("Save & Load") {
                    vm.client = KanboardClient(baseURL: url, token: token)
                    Task { await vm.load() }; showSettings = false
                }
            }
        }
       .task {
            if!url.isEmpty { vm.client = KanboardClient(baseURL: url, token: token); await vm.load()
                NotificationCenter.default.addObserver(forName:.EKEventStoreChanged, object: nil, queue:.main) { _ in
                    Task { await vm.reminderSync.checkForChangesFromReminders(client: vm.client, projectId: vm.projectId); await vm.load() }
                }
            } else { showSettings = true }
        }
    }
}
