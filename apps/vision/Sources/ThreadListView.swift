import SwiftUI

private enum ThreadFilter: String, CaseIterable, Hashable, Identifiable {
    case active
    case archived

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum VisionSelection: Hashable {
    case thread(String)
    case newTask(UUID, projectID: String?)
    case newProject(UUID)
}

struct ThreadListView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    @AppStorage("vision.tasks.groupByProject") private var groupByProject = false
    @State private var selection: VisionSelection?
    @State private var filter = ThreadFilter.active
    @State private var searchText = ""
    @State private var renameTarget: OrchestrationThreadShell?
    @State private var renameDraft = ""
    @State private var actionError: String?

    private var projects: [OrchestrationProject] {
        (model.snapshot?.projects ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var projectsByID: [String: OrchestrationProject] {
        Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    private var sourceThreads: [OrchestrationThreadShell] {
        switch filter {
        case .active:
            model.snapshot?.threads.filter { $0.archivedAt == nil } ?? []
        case .archived:
            model.archivedThreads.filter { $0.archivedAt != nil }
        }
    }

    private var visibleThreads: [OrchestrationThreadShell] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ordered(sourceThreads.filter { thread in
            guard !query.isEmpty else { return true }
            return thread.title.lowercased().contains(query)
                || thread.branch?.lowercased().contains(query) == true
                || projectsByID[thread.projectId]?.title.lowercased().contains(query) == true
        })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Tasks")
                .searchable(text: $searchText, prompt: "Search tasks")
                .toolbar { sidebarToolbar }
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .alert(
            "Rename Task",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: {
                    if !$0 {
                        renameTarget = nil
                        renameDraft = ""
                    }
                }
            )
        ) {
            TextField("Task name", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                renameDraft = ""
            }
            Button("Save") { finishRename() }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a short name that makes this task easy to find.")
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

    @ViewBuilder
    private var sidebar: some View {
        if projects.isEmpty && visibleThreads.isEmpty {
            ContentUnavailableView {
                Label("No tasks", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Add a workspace, then start a task on it.")
            } actions: {
                Button("New Project") { selection = .newProject(UUID()) }
            }
        } else if visibleThreads.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $selection) {
                if groupByProject {
                    groupedTaskRows
                } else {
                    flatTaskRows
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var flatTaskRows: some View {
        ForEach(visibleThreads) { thread in
            taskLink(
                thread,
                projectTitle: projectsByID[thread.projectId]?.title
            )
        }
        .onMove { source, destination in
            guard filter == .active, searchText.isEmpty else { return }
            moveThreads(visibleThreads, from: source, to: destination)
        }
    }

    private var groupedTaskRows: some View {
        ForEach(projects) { project in
            let projectThreads = visibleThreads.filter { $0.projectId == project.id }
            if !projectThreads.isEmpty {
                Section {
                    ForEach(projectThreads) { thread in
                        taskLink(thread, projectTitle: nil)
                    }
                    .onMove { source, destination in
                        guard filter == .active, searchText.isEmpty else { return }
                        moveThreads(projectThreads, from: source, to: destination)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(project.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            selection = .newTask(UUID(), projectID: project.id)
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New task in \(project.title)")
                    }
                }
            }
        }
    }

    private func taskLink(
        _ thread: OrchestrationThreadShell,
        projectTitle: String?
    ) -> some View {
        NavigationLink(value: VisionSelection.thread(thread.id)) {
            ThreadRow(
                thread: thread,
                projectTitle: projectTitle,
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
                onRename: {
                    renameDraft = thread.title
                    renameTarget = thread
                },
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

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .thread(threadID):
            ThreadDetailView(threadID: threadID)
                .id(threadID)
        case let .newTask(requestID, projectID):
            NewTaskView(
                projectID: projectID,
                onCancel: { selection = nil },
                onCreated: { selection = .thread($0) }
            )
            .id(requestID)
        case let .newProject(requestID):
            NewProjectView(
                onCancel: { selection = nil },
                onCreated: { selection = nil }
            )
            .id(requestID)
        case nil:
            ContentUnavailableView {
                Label("Select a task", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Choose a task from the sidebar or start a new one.")
            } actions: {
                Button("New Task") {
                    selection = .newTask(UUID(), projectID: nil)
                }
                .disabled(projects.isEmpty)
            }
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                selection = .newTask(UUID(), projectID: nil)
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .disabled(projects.isEmpty)

            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(ThreadFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                Toggle("Group by Project", isOn: $groupByProject)
                Divider()
                Button {
                    selection = .newProject(UUID())
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                Divider()
                Button("Disconnect") { Task { await model.signOut() } }
            } label: {
                Label("Task List Options", systemImage: "ellipsis.circle")
            }
        }
    }

    private func ordered(
        _ threads: [OrchestrationThreadShell]
    ) -> [OrchestrationThreadShell] {
        let order = Dictionary(uniqueKeysWithValues: model.threadOrder.enumerated().map {
            ($0.element, $0.offset)
        })
        return threads.sorted { left, right in
            switch (order[left.id], order[right.id]) {
            case let (leftIndex?, rightIndex?):
                return leftIndex < rightIndex
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                if (left.pinnedAt != nil) != (right.pinnedAt != nil) {
                    return left.pinnedAt != nil
                }
                return left.updatedAt > right.updatedAt
            }
        }
    }

    private func moveThreads(
        _ threads: [OrchestrationThreadShell],
        from source: IndexSet,
        to destination: Int
    ) {
        var ids = threads.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.setThreadOrder(ids)
    }

    private func finishRename() {
        guard let thread = renameTarget else { return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        renameTarget = nil
        renameDraft = ""
        perform { try await model.rename(threadID: thread.id, title: title) }
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
    let projectTitle: String?
    let onPin: () -> Void
    let onSettle: () -> Void
    let onRename: () -> Void
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let projectTitle {
                Text(projectTitle.uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Text(thread.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if thread.pinnedAt != nil {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if thread.hasPendingApprovals || thread.hasPendingUserInput {
                    Label("Needs you", systemImage: "exclamationmark")
                        .foregroundStyle(.orange)
                } else if let status = thread.session?.status,
                          status == "starting" || status == "running" {
                    HStack(spacing: 5) {
                        Image(systemName: "ellipsis")
                            .fontWeight(.semibold)
                        Text("Working")
                    }
                    .foregroundStyle(.tint)
                } else if thread.session?.status == "error" {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if thread.settledAt != nil {
                    Text("Complete")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
                    systemImage: thread.settledAt == nil
                        ? "checkmark.circle"
                        : "arrow.uturn.backward.circle"
                )
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: thread.archivedAt == nil ? .destructive : nil, action: onArchive) {
                Label(
                    thread.archivedAt == nil ? "Archive" : "Unarchive",
                    systemImage: thread.archivedAt == nil
                        ? "archivebox"
                        : "arrow.uturn.backward"
                )
            }
        }
    }
}
