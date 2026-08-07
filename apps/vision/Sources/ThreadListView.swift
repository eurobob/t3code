import SwiftUI

struct ThreadListView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    private var projectsByID: [String: OrchestrationProject] {
        Dictionary(uniqueKeysWithValues: (model.snapshot?.projects ?? []).map { ($0.id, $0) })
    }

    /// Most recently touched first — the same ordering the other clients use,
    /// and the only one that makes sense when several agents are working.
    private var threads: [OrchestrationThreadShell] {
        (model.snapshot?.threads ?? [])
            .filter { $0.archivedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if threads.isEmpty {
                    ContentUnavailableView(
                        "No threads",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a task from another T3 Code client and it will appear here.")
                    )
                } else {
                    List(threads) { thread in
                        ThreadRow(thread: thread, project: projectsByID[thread.projectId])
                    }
                }
            }
            .navigationTitle(model.environment?.label ?? "T3 Code")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect") { Task { await model.signOut() } }
                }
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: OrchestrationThreadShell
    let project: OrchestrationProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 10) {
                if let project {
                    Label(project.title, systemImage: "folder")
                }
                if let branch = thread.branch {
                    Label(branch, systemImage: "arrow.trianglehead.branch")
                }
                if thread.hasPendingApprovals {
                    // Approvals are the interrupt that actually needs a human,
                    // so they get the one bit of colour in the row.
                    Label("Needs approval", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
