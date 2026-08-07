import SwiftUI

struct NewTaskView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    @SwiftUI.Environment(\.dismiss) private var dismiss

    let onCreated: (String) -> Void

    @State private var projectID: String
    @State private var title = ""
    @State private var prompt = ""
    @State private var modelID = ""
    @State private var runtimeModeID = RuntimeMode.fullAccess.rawValue
    @State private var interactionModeID = InteractionMode.default.rawValue
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(projectID: String?, onCreated: @escaping (String) -> Void) {
        _projectID = State(initialValue: projectID ?? "")
        self.onCreated = onCreated
    }

    private var projects: [OrchestrationProject] {
        (model.snapshot?.projects ?? [])
            .filter { $0.deletedAt == nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var selectedProject: OrchestrationProject? {
        projects.first { $0.id == projectID }
    }

    private var selectedModel: ModelSelection? {
        if let projectDefault = selectedProject?.defaultModelSelection,
           modelID == modelOptionID(projectDefault) {
            return projectDefault
        }
        return model.availableModels.first { $0.id == modelID }?.selection
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("Task") {
                    Picker("Project", selection: $projectID) {
                        ForEach(projects) { project in
                            Text(project.title).tag(project.id)
                        }
                    }
                    TextField("Name (optional)", text: $title)
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                }

                Section("Agent") {
                    if model.availableModels.isEmpty {
                        Text("No configured provider models are available.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $modelID) {
                            ForEach(model.availableModels) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                    }
                    Picker("Access", selection: $runtimeModeID) {
                        Text("Ask for approval").tag(RuntimeMode.approvalRequired.rawValue)
                        Text("Auto-accept edits").tag(RuntimeMode.autoAcceptEdits.rawValue)
                        Text("Automatic").tag(RuntimeMode.auto.rawValue)
                        Text("Full access").tag(RuntimeMode.fullAccess.rawValue)
                    }
                    Picker("Mode", selection: $interactionModeID) {
                        Text("Build").tag(InteractionMode.default.rawValue)
                        Text("Plan").tag(InteractionMode.plan.rawValue)
                    }
                }
            }
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { createTask() }
                        .disabled(
                            isCreating
                                || selectedProject == nil
                                || selectedModel == nil
                                || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .frame(minWidth: 620, minHeight: 680)
        .task { configureDefaults() }
        .onChange(of: projectID) { configureModelDefault() }
    }

    private func configureDefaults() {
        if projectID.isEmpty { projectID = projects.first?.id ?? "" }
        configureModelDefault()
    }

    private func configureModelDefault() {
        guard let project = selectedProject else {
            modelID = model.availableModels.first?.id ?? ""
            return
        }
        if let selection = model.defaultModel(for: project) {
            modelID = modelOptionID(selection)
        } else {
            modelID = model.availableModels.first?.id ?? ""
        }
    }

    private func createTask() {
        guard !isCreating,
              let project = selectedProject,
              let selection = selectedModel else { return }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        Task {
            do {
                let threadID = try await model.createThreadAndSend(
                    projectID: project.id,
                    title: resolvedTitle(prompt: trimmedPrompt),
                    text: trimmedPrompt,
                    model: selection,
                    runtimeMode: RuntimeMode(rawValue: runtimeModeID) ?? .fullAccess,
                    interactionMode: InteractionMode(rawValue: interactionModeID) ?? .default
                )
                dismiss()
                onCreated(threadID)
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func resolvedTitle(prompt: String) -> String {
        let explicit = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let compact = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > 72 else { return compact }
        return "\(compact.prefix(69))…"
    }

    private func modelOptionID(_ selection: ModelSelection) -> String {
        "\(selection.instanceId):\(selection.model)"
    }
}

struct NewProjectView: View {
    @SwiftUI.Environment(AppModel.self) private var model
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var workspaceRoot = ""
    @State private var modelID: String?
    @State private var createDirectory = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("Workspace") {
                    TextField("Project name", text: $title)
                    TextField("Absolute workspace path", text: $workspaceRoot)
                        .textInputAutocapitalization(.never)
                    Toggle("Create the directory if missing", isOn: $createDirectory)
                }

                Section("Defaults") {
                    Picker("Model", selection: $modelID) {
                        Text("Server default").tag(String?.none)
                        ForEach(model.availableModels) { option in
                            Text(option.label).tag(String?.some(option.id))
                        }
                    }
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createProject() }
                        .disabled(
                            isCreating
                                || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func createProject() {
        guard !isCreating else { return }
        let projectTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectTitle.isEmpty, !root.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        let selection = model.availableModels.first { $0.id == modelID }?.selection
        Task {
            do {
                try await model.createProject(
                    title: projectTitle,
                    workspaceRoot: root,
                    defaultModel: selection,
                    createWorkspaceRootIfMissing: createDirectory
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
