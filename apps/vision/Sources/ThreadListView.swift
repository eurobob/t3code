import Foundation
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
    @SwiftUI.Environment(\.openWindow) private var openWindow

    @AppStorage("vision.tasks.groupByProject") private var groupByProject = false
    @State private var selection: VisionSelection?
    @State private var filter = ThreadFilter.active
    @State private var searchText = ""
    @State private var renameTarget: OrchestrationThreadShell?
    @State private var renameDraft = ""
    @State private var actionError: String?
    @State private var viewedTurnStates: [String: String] =
        UserDefaults.standard.dictionary(forKey: "vision.tasks.viewedTurnStates")
            as? [String: String] ?? [:]

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

    private var unfinishedThreads: [OrchestrationThreadShell] {
        visibleThreads.filter { $0.settledAt == nil }
    }

    private var completedThreads: [OrchestrationThreadShell] {
        visibleThreads.filter { $0.settledAt != nil }
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
        .onChange(of: selection) {
            markSelectedThreadViewed()
        }
        .onChange(of: selectedThreadStateSignature) {
            markSelectedThreadViewed()
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
            List {
                if groupByProject {
                    groupedTaskRows
                } else {
                    flatTaskRows
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var flatTaskRows: some View {
        ForEach(unfinishedThreads) { thread in
            taskLink(
                thread,
                projectTitle: projectsByID[thread.projectId]?.title
            )
        }
        .onMove { source, destination in
            guard filter == .active, searchText.isEmpty else { return }
            moveThreads(unfinishedThreads, from: source, to: destination)
        }

        completedTaskRows
    }

    @ViewBuilder
    private var groupedTaskRows: some View {
        ForEach(projects) { project in
            let projectThreads = unfinishedThreads.filter { $0.projectId == project.id }
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

        completedTaskRows
    }

    @ViewBuilder
    private var completedTaskRows: some View {
        if !completedThreads.isEmpty {
            Section {
                ForEach(completedThreads) { thread in
                    taskLink(
                        thread,
                        projectTitle: projectsByID[thread.projectId]?.title
                    )
                }
                .onMove { source, destination in
                    guard filter == .active, searchText.isEmpty else { return }
                    moveThreads(completedThreads, from: source, to: destination)
                }
            } header: {
                Text("Completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func taskLink(
        _ thread: OrchestrationThreadShell,
        projectTitle: String?
    ) -> some View {
        Button {
            selection = .thread(thread.id)
            markViewed(thread)
        } label: {
            ThreadRow(
                thread: thread,
                projectTitle: projectTitle,
                hasUnread: hasUnreadUpdate(thread),
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
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowBackground(
            selection == .thread(thread.id)
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
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
                Button {
                    openWindow(id: "speech-lab")
                } label: {
                    Label("Speech Lab", systemImage: "waveform.and.mic")
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

    private var selectedThreadStateSignature: String? {
        guard case let .thread(threadID) = selection,
              let thread = ((model.snapshot?.threads ?? []) + model.archivedThreads)
                .first(where: { $0.id == threadID }),
              let signature = turnStateSignature(thread) else { return nil }
        return "\(threadID):\(signature)"
    }

    private func turnStateSignature(_ thread: OrchestrationThreadShell) -> String? {
        guard let turn = thread.latestTurn else { return nil }
        return "\(turn.turnId):\(turn.state)"
    }

    private func hasUnreadUpdate(_ thread: OrchestrationThreadShell) -> Bool {
        guard let turn = thread.latestTurn,
              turn.state == "completed" || turn.state == "interrupted" || turn.state == "error",
              let signature = turnStateSignature(thread),
              let viewed = viewedTurnStates[thread.id] else { return false }
        return viewed != signature
    }

    private func markSelectedThreadViewed() {
        guard case let .thread(threadID) = selection,
              let thread = ((model.snapshot?.threads ?? []) + model.archivedThreads)
                .first(where: { $0.id == threadID }) else { return }
        markViewed(thread)
    }

    private func markViewed(_ thread: OrchestrationThreadShell) {
        guard let signature = turnStateSignature(thread),
              viewedTurnStates[thread.id] != signature else { return }
        viewedTurnStates[thread.id] = signature
        UserDefaults.standard.set(
            viewedTurnStates,
            forKey: "vision.tasks.viewedTurnStates"
        )
    }
}

private struct ThreadRow: View {
    @SwiftUI.Environment(\.openWindow) private var openWindow

    let thread: OrchestrationThreadShell
    let projectTitle: String?
    let hasUnread: Bool
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

            ThreadStatusPill(presentation: statusPresentation)
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
                    thread.settledAt == nil ? "Settle" : "Unsettle",
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

    private var statusPresentation: ThreadStatusPresentation {
        if thread.hasPendingApprovals || thread.hasPendingUserInput {
            return .init(title: "Needs You", systemImage: "exclamationmark", color: .orange)
        }
        if let status = thread.session?.status,
           status == "starting" || status == "running" {
            return .init(title: "Working", systemImage: "ellipsis", color: .blue)
        }
        if thread.session?.status == "error" {
            return .init(
                title: "Error",
                systemImage: "exclamationmark.triangle.fill",
                color: .red
            )
        }
        if hasUnread {
            return .init(title: "Updated", systemImage: "circle.fill", color: .blue)
        }
        if thread.settledAt != nil {
            return .init(title: "Complete", systemImage: "checkmark", color: .secondary)
        }
        return .init(title: "Ready", systemImage: "circle", color: .secondary)
    }
}

private struct ThreadStatusPresentation {
    let title: String
    let systemImage: String
    let color: Color
}

private struct ThreadStatusPill: View {
    let presentation: ThreadStatusPresentation

    var body: some View {
        Label(presentation.title, systemImage: presentation.systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(presentation.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(presentation.color.opacity(0.12), in: Capsule())
    }
}
