import SwiftUI
import EventKit
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var vm = BoardViewModel()
    @AppStorage("kb_url") private var url = ""
    @AppStorage("kb_project") private var projectId = 1
    @State private var token = KeychainTokenStore.load()
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            board
                .navigationTitle("Board")
                .toolbar { Button("Settings") { showSettings = true } }
        }
        .sheet(isPresented: $showSettings) { settings }
        .alert("Something went wrong", isPresented: hasError) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .task {
            guard !url.isEmpty, !token.isEmpty else {
                showSettings = true
                return
            }
            vm.configure(baseURL: url, token: token, projectId: projectId)
            await vm.load()
        }
        // Registered by SwiftUI for the lifetime of the view, so no observer token to leak.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await vm.handleReminderChange() }
        }
    }

    private var board: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(vm.columns) { column in
                    columnView(column)
                }
            }
            .padding()
        }
    }

    private func columnView(_ column: BoardViewModel.BoardColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(column.name)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .padding(8)
            ForEach(column.tasks) { task in
                Text(task.title)
                    .font(.system(.body, design: .rounded))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
                    .onDrag { NSItemProvider(object: "\(task.id)" as NSString) }
            }
            Button("+ Add a card") {
                Task { await vm.addTask(title: "New task", to: column.id) }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(8)
        }
        .frame(width: 300)
        .background(Color(.systemGroupedBackground))
        .cornerRadius(16)
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers, into: column.id)
        }
    }

    private var settings: some View {
        NavigationView {
            Form {
                Section("Kanboard Server") {
                    TextField("https://kanboard.example.com", text: $url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("API Token", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Stepper("Project ID: \(projectId)", value: $projectId, in: 1...9999)
                }
                Button("Save & Load", action: save)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.isEmpty)
            }
            .navigationTitle("Settings")
        }
    }

    private var hasError: Binding<Bool> {
        Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })
    }

    private func save() {
        url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainTokenStore.save(token)
        vm.configure(baseURL: url, token: token, projectId: projectId)
        showSettings = false
        Task { await vm.load() }
    }

    /// The drag payload carries the task id, so the drop is resolved from what was actually
    /// dropped rather than from leftover drag state.
    private func handleDrop(_ providers: [NSItemProvider], into columnId: Int) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        // Capture only the view model: the completion handler is @Sendable, and the view
        // itself is not, so `self` must not be captured here.
        _ = provider.loadObject(ofClass: NSString.self) { [vm] object, _ in
            guard let text = object as? NSString, let taskId = Int(text as String) else { return }
            Task { @MainActor in
                guard let found = vm.task(withId: taskId), found.columnId != columnId else { return }
                await vm.move(task: found.task, to: columnId)
            }
        }
        return true
    }
}
