import SwiftUI

enum VisionRoute: Hashable {
    case project(String)
    case thread(String)
}

private enum ThreadFilter: String, CaseIterable, Hashable, Identifiable {
    case active
    case archived

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ThreadListView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    @State private var path: [VisionRoute] = []
    @State private var filter = ThreadFilter.active
    @State private var searchText = ""
    @State private var showingNewTask = false
    @State private var showingNewProject = false
    @State private var initialProjectID: String?
    @State private var renameTarget: OrchestrationThreadShell?
    @State private var actionError: String?

    private var projects: [OrchestrationProject] {
        (model.snapshot?.projects ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var sourceThreads: [OrchestrationThreadShell] {
        switch filter {
        case .active:
            model.snapshot?.threads.filter { $0.archivedAt == nil } ?? []
        case .archived:
            model.archivedThreads.filter { $0.archivedAt != nil }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No projects", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Add a workspace, then start a task on it.")
                    } actions: {
                        Button("New Project") { showingNewProject = true }
                    }
                } else {
                    taskList
                }
            }
            .navigationTitle(model.environment?.label ?? "T3 Code")
            .navigationDestination(for: VisionRoute.self) { route in
                switch route {
                case let .project(projectID):
                    ProjectDetailView(projectID: projectID, path: $path)
                case let .thread(threadID):
                    ThreadDetailView(threadID: threadID)
                }
            }
            .searchable(text: $searchText, prompt: "Search tasks")
            .toolbar { toolbarContent }
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskView(projectID: initialProjectID) { threadID in
                path.append(.thread(threadID))
            }
            .environment(model)
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView()
                .environment(model)
        }
        .sheet(item: $renameTarget) { thread in
            RenameTaskView(thread: thread) { title in
                perform { try await model.rename(threadID: thread.id, title: title) }
            }
        }
        .alert(
            "Task action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "Unknown error")
        }
    }

    private var taskList: some View {
        List {
            ForEach(projects) { project in
                Section {
                    let projectThreads = threads(for: project.id)
                    if projectThreads.isEmpty {
                        Text(filter == .active ? "No active tasks" : "No archived tasks")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(projectThreads) { thread in
                            NavigationLink(value: VisionRoute.thread(thread.id)) {
                                ThreadRow(
                                    thread: thread,
                                    onPin: {
                                        perform {
                                            try await model.pin(
                                                threadID: thread.id,
                                                pinned: thread.pinnedAt == nil
                                            )
                                        }
                                    },
                                    onSettle: {
                                        perform {
                                            try await model.settle(
                                                threadID: thread.id,
                                                settled: thread.settledAt == nil
                                            )
                                        }
                                    },
                                    onRename: { renameTarget = thread },
                                    onArchive: {
                                        perform {
                                            try await model.archive(
                                                threadID: thread.id,
                                                archived: thread.archivedAt == nil
                                            )
                                        }
                                    }
                                )
                            }
                        }
                        .onMove { source, destination in
                            guard filter == .active else { return }
                            moveThreads(
                                projectID: project.id,
                                from: source,
                                to: destination
                            )
                        }
                    }
                } header: {
                    HStack {
                        NavigationLink(value: VisionRoute.project(project.id)) {
                            Label(project.title, systemImage: "folder")
                        }
                        Spacer()
                        Button {
                            initialProjectID = project.id
                            showingNewTask = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New task in \(project.title)")
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            EditButton()
                .disabled(filter == .archived)

            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(ThreadFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                Divider()
                Button {
                    initialProjectID = nil
                    showingNewTask = true
                } label: {
                    Label("New Task", systemImage: "plus.bubble")
                }
                Button {
                    showingNewProject = true
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                Divider()
                Button("Disconnect") { Task { await model.signOut() } }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
    }

    private func threads(for projectID: String) -> [OrchestrationThreadShell] {
        let order = Dictionary(uniqueKeysWithValues: model.threadOrder.enumerated().map {
            ($0.element, $0.offset)
        })
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sourceThreads
            .filter { thread in
                guard thread.projectId == projectID else { return false }
                guard !query.isEmpty else { return true }
                return thread.title.lowercased().contains(query)
                    || thread.branch?.lowercased().contains(query) == true
            }
            .sorted { left, right in
                switch (order[left.id], order[right.id]) {
                case let (leftIndex?, rightIndex?):
                    leftIndex < rightIndex
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case (.none, .none):
                    if (left.pinnedAt != nil) != (right.pinnedAt != nil) {
                        return left.pinnedAt != nil
                    }
                    return left.updatedAt > right.updatedAt
                }
            }
    }

    private func moveThreads(
        projectID: String,
        from source: IndexSet,
        to destination: Int
    ) {
        var ids = threads(for: projectID).map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.setThreadOrder(ids)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct ThreadRow: View {
    @SwiftUI.Environment(\.openWindow) private var openWindow

    let thread: OrchestrationThreadShell
    let onPin: () -> Void
    let onSettle: () -> Void
    let onRename: () -> Void
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(thread.title)
                    .font(.headline)
                    .lineLimit(2)
                if thread.pinnedAt != nil {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if let branch = thread.branch {
                    Label(branch, systemImage: "arrow.trianglehead.branch")
                }
                if let status = thread.session?.status,
                   status == "starting" || status == "running" {
                    Label(status.capitalized, systemImage: "circle.dotted")
                        .foregroundStyle(.green)
                }
                if thread.hasPendingApprovals || thread.hasPendingUserInput {
                    Label("Needs input", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                openWindow(id: "thread", value: thread.id)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Button(action: onPin) {
                Label(
                    thread.pinnedAt == nil ? "Pin" : "Unpin",
                    systemImage: thread.pinnedAt == nil ? "pin" : "pin.slash"
                )
            }
            Button(action: onSettle) {
                Label(
                    thread.settledAt == nil ? "Mark Done" : "Mark Active",
                    systemImage: thread.settledAt == nil ? "checkmark.circle" : "arrow.uturn.backward.circle"
                )
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: thread.archivedAt == nil ? .destructive : nil, action: onArchive) {
                Label(
                    thread.archivedAt == nil ? "Archive" : "Unarchive",
                    systemImage: thread.archivedAt == nil ? "archivebox" : "arrow.uturn.backward"
                )
            }
        }
    }
}

private struct ProjectDetailView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    let projectID: String
    @Binding var path: [VisionRoute]
    @State private var showingNewTask = false

    private var project: OrchestrationProject? {
        model.snapshot?.projects.first { $0.id == projectID }
    }

    private var threads: [OrchestrationThreadShell] {
        (model.snapshot?.threads ?? [])
            .filter { $0.projectId == projectID && $0.archivedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if let project {
                List {
                    Section("Workspace") {
                        LabeledContent("Path", value: project.workspaceRoot)
                        if let model = project.defaultModelSelection {
                            LabeledContent("Default model", value: model.model)
                        }
                    }
                    Section("Tasks") {
                        if threads.isEmpty {
                            Text("No active tasks")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(threads) { thread in
                                NavigationLink(value: VisionRoute.thread(thread.id)) {
                                    VStack(alignment: .leading) {
                                        Text(thread.title)
                                        if let branch = thread.branch {
                                            Text(branch)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(project.title)
                .toolbar {
                    Button {
                        showingNewTask = true
                    } label: {
                        Label("New Task", systemImage: "plus")
                    }
                }
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark")
            }
        }
        .sheet(isPresented: $showingNewTask) {
            NewTaskView(projectID: projectID) { threadID in
                path.append(.thread(threadID))
            }
            .environment(model)
        }
    }
}

private struct RenameTaskView: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let thread: OrchestrationThreadShell
    let onRename: (String) -> Void
    @State private var title: String

    init(thread: OrchestrationThreadShell, onRename: @escaping (String) -> Void) {
        self.thread = thread
        self.onRename = onRename
        _title = State(initialValue: thread.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Task name", text: $title)
            }
            .navigationTitle("Rename Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onRename(trimmed)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 240)
    }
}
