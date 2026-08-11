import SwiftUI

private enum VisionWorkspaceMode: String, CaseIterable {
    case currentCheckout
    case worktree

    var title: String {
        switch self {
        case .currentCheckout: "Current checkout"
        case .worktree: "New worktree"
        }
    }
}

struct NewTaskView: View {
    @SwiftUI.Environment(AppModel.self) private var model

    let onCancel: () -> Void
    let onCreated: (String) -> Void

    @State private var projectID: String
    @State private var title = ""
    @State private var promptDictation = VisionDictationDraft()
    @State private var modelID = ""
    @State private var stringOptions: [String: String] = [:]
    @State private var booleanOptions: [String: Bool] = [:]
    @State private var preservedSelection: ModelSelection?
    @State private var runtimeModeID = RuntimeMode.fullAccess.rawValue
    @State private var interactionModeID = InteractionMode.default.rawValue
    @State private var workspaceMode = VisionWorkspaceMode.worktree
    @State private var branches: [VisionWorkspaceBranch] = []
    @State private var selectedBranchID = ""
    @State private var startFromOrigin = true
    @State private var branchesLoading = false
    @State private var branchLoadError: String?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var attachments: [VisionDraftAttachment] = []
    @State private var microphoneHovered = false

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

    private var selectedBranch: VisionWorkspaceBranch? {
        branches.first { $0.id == selectedBranchID }
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
                taskDescriptionEditor
                VisionAttachmentStrip(attachments: $attachments)
                HStack {
                    VisionImageAttachmentPicker(
                        attachments: $attachments,
                        isEnabled: !isCreating
                    )
                    Text(attachments.isEmpty ? "Add images" : "\(attachments.count) of 8 images")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Workspace") {
                Picker("Checkout", selection: $workspaceMode) {
                    ForEach(VisionWorkspaceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if branchesLoading, branches.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading branches…")
                            .foregroundStyle(.secondary)
                    }
                } else if let branchLoadError {
                    Label(branchLoadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Retry") {
                        Task { await loadBranches(refresh: true) }
                    }
                } else if workspaceMode == .worktree {
                    if branches.isEmpty {
                        Text("No Git branches found. Use the current checkout for this project.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Branch origin", selection: $selectedBranchID) {
                            ForEach(branches) { branch in
                                Text(branch.label).tag(branch.id)
                            }
                        }
                        Toggle("Start from latest origin", isOn: $startFromOrigin)
                    }
                } else if let selectedBranch {
                    LabeledContent("Branch", value: selectedBranch.name)
                }

                Text(
                    workspaceMode == .worktree
                        ? "Creates an isolated worktree before the agent starts."
                        : "Runs the task in the project's current checkout."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .disabled(isCreating)
        .navigationTitle("New Task")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    promptDictation.cancel()
                    onCancel()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start") { startTask() }
                    .disabled(
                        isCreating
                            || selectedProject == nil
                            || selectedModel == nil
                            || (workspaceMode == .worktree && selectedBranch == nil)
                            || (!promptDictation.isDictating
                                && promptDictation.text
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                                && attachments.isEmpty)
                    )
            }
        }
        .task { configureDefaults() }
        .task(id: projectID) { await loadBranches() }
        .onChange(of: projectID) { configureModelDefault() }
        .onChange(of: modelID) { configureModelOptions() }
        .onChange(of: workspaceMode) { selectDefaultBranch() }
        .onDisappear { promptDictation.cancel() }
    }

    private var taskDescriptionEditor: some View {
        @Bindable var promptDictation = promptDictation
        return VStack(alignment: .leading, spacing: 12) {
            if let error = promptDictation.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let label = promptDictation.phase.label {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.caption.weight(.semibold))
                        if !promptDictation.volatileText.isEmpty {
                            Text(promptDictation.volatileText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        promptDictation.cancel()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .foregroundStyle(.white)
                }
            }

            if promptDictation.isDictating {
                if !promptDictation.previewText.isEmpty {
                    Text(promptDictation.previewText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else {
                TextField(
                    "What should the agent do?",
                    text: $promptDictation.text,
                    axis: .vertical
                )
                .lineLimit(4...12)
            }

            Button {
                if promptDictation.isDictating {
                    promptDictation.finish()
                } else {
                    promptDictation.begin(vocabulary: model.dictationVocabulary)
                }
            } label: {
                Image(systemName: promptDictation.isDictating ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(taskMicrophoneColor, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.72), lineWidth: 2)
                            .padding(5)
                    }
                    .contentShape(.interaction, Circle())
                    .contentShape(.hoverEffect, Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
            .onHover { microphoneHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: microphoneHovered)
            .animation(.easeOut(duration: 0.12), value: promptDictation.isDictating)
            .opacity(isCreating ? 0.4 : 1)
            .disabled(isCreating)
            .accessibilityLabel(
                promptDictation.isDictating ? "Stop task dictation" : "Start task dictation"
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 4)
    }

    private var taskMicrophoneColor: Color {
        if promptDictation.isDictating { return .red }
        if microphoneHovered { return .green }
        return Color.secondary.opacity(0.45)
    }

    private func configureDefaults() {
        if projectID.isEmpty { projectID = projects.first?.id ?? "" }
        configureModelDefault()
    }

    private func loadBranches(refresh: Bool = false) async {
        let requestedProjectID = projectID
        guard !requestedProjectID.isEmpty else { return }

        branchesLoading = true
        branchLoadError = nil
        branches = []
        selectedBranchID = ""
        do {
            let loaded = try await model.workspaceBranches(
                projectID: requestedProjectID,
                refresh: refresh
            )
            guard !Task.isCancelled, projectID == requestedProjectID else { return }
            branches = loaded.sorted(by: Self.branchSort)
            if !branches.contains(where: { $0.id == selectedBranchID }) {
                selectDefaultBranch()
            }
        } catch is CancellationError {
            return
        } catch {
            guard projectID == requestedProjectID else { return }
            branches = []
            selectedBranchID = ""
            branchLoadError = error.localizedDescription
        }
        guard projectID == requestedProjectID else { return }
        branchesLoading = false
    }

    private func selectDefaultBranch() {
        let branch: VisionWorkspaceBranch? = switch workspaceMode {
        case .currentCheckout:
            branches.first { $0.isCurrent }
                ?? branches.first { $0.isDefault && !$0.isRemote }
                ?? branches.first { !$0.isRemote }
                ?? branches.first
        case .worktree:
            branches.first { $0.isDefault && !$0.isRemote }
                ?? branches.first { $0.isCurrent }
                ?? branches.first { $0.isDefault }
                ?? branches.first { !$0.isRemote }
                ?? branches.first
        }
        selectedBranchID = branch?.id ?? ""
    }

    private static func branchSort(
        _ lhs: VisionWorkspaceBranch,
        _ rhs: VisionWorkspaceBranch
    ) -> Bool {
        let lhsRank = lhs.isCurrent ? 0 : lhs.isDefault ? 1 : lhs.isRemote ? 3 : 2
        let rhsRank = rhs.isCurrent ? 0 : rhs.isDefault ? 1 : rhs.isRemote ? 3 : 2
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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

    private func startTask() {
        guard !isCreating else { return }
        isCreating = true
        if promptDictation.isDictating {
            promptDictation.finish { finished in
                guard finished else {
                    isCreating = false
                    return
                }
                createTask()
            }
        } else {
            createTask()
        }
    }

    private func createTask() {
        guard let project = selectedProject,
              let selection = selectedModel else {
            isCreating = false
            return
        }
        let trimmedPrompt = promptDictation.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty || !attachments.isEmpty else {
            isCreating = false
            promptDictation.presentError("Dictate or type a task description before starting.")
            return
        }

        errorMessage = nil
        Task {
            do {
                let uploads = try attachments.map { try $0.uploadValue() }
                let threadID = try await model.createThreadAndSend(
                    projectID: project.id,
                    title: resolvedTitle(prompt: trimmedPrompt),
                    text: trimmedPrompt,
                    model: selection,
                    runtimeMode: RuntimeMode(rawValue: runtimeModeID) ?? .fullAccess,
                    interactionMode: InteractionMode(rawValue: interactionModeID) ?? .default,
                    createWorktree: workspaceMode == .worktree,
                    baseBranch: selectedBranch?.name,
                    startFromOrigin: workspaceMode == .worktree && startFromOrigin,
                    attachments: uploads
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
        if prompt.isEmpty { return "Image task" }
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
