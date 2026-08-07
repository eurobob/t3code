import SwiftUI

struct NewTaskView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    let onCancel: () -> Void
    let onCreated: (String) -> Void

    @State private var projectID: String
    @State private var title = ""
    @State private var prompt = ""
    @State private var modelID = ""
    @State private var stringOptions: [String: String] = [:]
    @State private var booleanOptions: [String: Bool] = [:]
    @State private var preservedSelection: ModelSelection?
    @State private var runtimeModeID = RuntimeMode.fullAccess.rawValue
    @State private var interactionModeID = InteractionMode.default.rawValue
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(
        projectID: String?,
        onCancel: @escaping () -> Void,
        onCreated: @escaping (String) -> Void
    ) {
        _projectID = State(initialValue: projectID ?? "")
        self.onCancel = onCancel
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

    private var selectedModelOption: VisionModelOption? {
        model.availableModels.first { $0.id == modelID }
    }

    private var selectedModel: ModelSelection? {
        guard let option = selectedModelOption else { return nil }
        guard !option.optionDescriptors.isEmpty else {
            return baseSelection(for: option)
        }
        let selections: [ModelSelection.OptionSelection] = option.optionDescriptors.compactMap { descriptor in
            switch descriptor {
            case let .select(value):
                guard let selected = stringOptions[value.id], !selected.isEmpty else {
                    return nil
                }
                return ModelSelection.OptionSelection(
                    id: value.id,
                    value: .string(selected)
                )
            case let .boolean(value):
                return ModelSelection.OptionSelection(
                    id: value.id,
                    value: .bool(booleanOptions[value.id] ?? false)
                )
            }
        }
        return ModelSelection(
            instanceId: option.selection.instanceId,
            model: option.selection.model,
            options: selections.isEmpty ? nil : selections
        )
    }

    var body: some View {
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

            if let option = selectedModelOption, !option.optionDescriptors.isEmpty {
                Section("Model options") {
                    ForEach(Array(option.optionDescriptors.enumerated()), id: \.offset) { _, descriptor in
                        switch descriptor {
                        case let .select(value):
                            Picker(
                                value.label,
                                selection: stringOptionBinding(id: value.id)
                            ) {
                                ForEach(value.options) { choice in
                                    Text(choice.label).tag(choice.id)
                                }
                            }
                            if let description = value.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case let .boolean(value):
                            Toggle(
                                value.label,
                                isOn: booleanOptionBinding(id: value.id)
                            )
                            if let description = value.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("New Task")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
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
        .task { configureDefaults() }
        .onChange(of: projectID) { configureModelDefault() }
        .onChange(of: modelID) { configureModelOptions() }
    }

    private func configureDefaults() {
        if projectID.isEmpty { projectID = projects.first?.id ?? "" }
        configureModelDefault()
    }

    private func configureModelDefault() {
        guard let project = selectedProject else {
            preservedSelection = nil
            modelID = model.availableModels.first?.id ?? ""
            configureModelOptions()
            return
        }
        if let selection = model.defaultModel(for: project) {
            preservedSelection = selection
            modelID = modelOptionID(selection)
        } else {
            preservedSelection = nil
            modelID = model.availableModels.first?.id ?? ""
        }
        configureModelOptions()
    }

    private func configureModelOptions() {
        guard let option = selectedModelOption else {
            stringOptions = [:]
            booleanOptions = [:]
            return
        }

        var preservedStrings: [String: String] = [:]
        var preservedBooleans: [String: Bool] = [:]
        for selection in baseSelection(for: option).options ?? [] {
            switch selection.value {
            case let .string(value):
                preservedStrings[selection.id] = value
            case let .bool(value):
                preservedBooleans[selection.id] = value
            default:
                break
            }
        }

        var nextStrings: [String: String] = [:]
        var nextBooleans: [String: Bool] = [:]
        for descriptor in option.optionDescriptors {
            switch descriptor {
            case let .select(value):
                nextStrings[value.id] = preservedStrings[value.id]
                    ?? value.currentValue
                    ?? value.options.first(where: { $0.isDefault == true })?.id
                    ?? value.options.first?.id
                    ?? ""
            case let .boolean(value):
                nextBooleans[value.id] = preservedBooleans[value.id]
                    ?? value.currentValue
                    ?? false
            }
        }
        stringOptions = nextStrings
        booleanOptions = nextBooleans
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

    private func baseSelection(for option: VisionModelOption) -> ModelSelection {
        if let preservedSelection,
           modelOptionID(preservedSelection) == option.id {
            return preservedSelection
        }
        if let projectDefault = selectedProject?.defaultModelSelection,
           modelOptionID(projectDefault) == option.id {
            return projectDefault
        }
        return option.selection
    }

    private func stringOptionBinding(id: String) -> Binding<String> {
        Binding(
            get: { stringOptions[id] ?? "" },
            set: { stringOptions[id] = $0 }
        )
    }

    private func booleanOptionBinding(id: String) -> Binding<Bool> {
        Binding(
            get: { booleanOptions[id] ?? false },
            set: { booleanOptions[id] = $0 }
        )
    }
}

struct NewProjectView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    let onCancel: () -> Void
    let onCreated: () -> Void

    @State private var title = ""
    @State private var workspaceRoot = ""
    @State private var modelID: String?
    @State private var createDirectory = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
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
                Button("Cancel", action: onCancel)
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
                onCreated()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
