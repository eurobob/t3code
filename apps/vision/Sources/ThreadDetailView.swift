import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class ThreadDetailModel {
    private struct CachedTaskSummary: Codable {
        let sourceRevision: String
        let summary: GeneratedTaskSummary
    }

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum ActionState: Equatable {
        case idle
        case sending
        case requestingInterrupt
        case waitingForInterruption
        case sendingRedirect

        var label: String? {
            switch self {
            case .idle: nil
            case .sending: "Sending…"
            case .requestingInterrupt: "Dispatching interrupt…"
            case .waitingForInterruption: "Waiting for the running turn to stop…"
            case .sendingRedirect: "Sending redirect as the next turn…"
            }
        }
    }

    enum DictationPhase: Equatable {
        case idle
        case preparing
        case listening
        case finishing

        var label: String? {
            switch self {
            case .idle: nil
            case .preparing: "Preparing dictation…"
            case .listening: "Listening…"
            case .finishing: "Finishing dictation…"
            }
        }
    }

    private enum ActionError: LocalizedError {
        case threadUnavailable
        case eventStreamEnded
        case interruptFailed(String)

        var errorDescription: String? {
            switch self {
            case .threadUnavailable:
                "The thread state is not available yet."
            case .eventStreamEnded:
                "The thread event stream ended before the turn stopped."
            case let .interruptFailed(detail):
                "The provider could not interrupt this turn: \(detail)"
            }
        }
    }

    private enum TurnSettlement {
        case interrupted
        case alreadySettled(String)
    }

    let threadID: String

    private(set) var loadState: LoadState = .loading
    private(set) var detail: OrchestrationThreadDetailSnapshot?
    private(set) var liveError: String?
    private(set) var actionState: ActionState = .idle
    private(set) var actionError: String?
    private(set) var actionNotice: String?
    private(set) var dictationPhase: DictationPhase = .idle
    private(set) var volatileDictation = ""
    private(set) var dictationError: String?
    private(set) var submissionRevision = 0
    private(set) var draftRestorationRevision = 0
    private(set) var awaitingAgentStart = false
    private(set) var generatedSummary: GeneratedTaskSummary?
    private(set) var generatedSummaryRevision: String?
    private(set) var summaryIsLoading = false
    private(set) var summaryError: String?
    var draft = ""

    @ObservationIgnored
    private var eventsTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var actionTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshGeneration = 0
    @ObservationIgnored
    private let dictationController: VisionDictationController
    @ObservationIgnored
    private var dictationTask: Task<Void, Never>?
    @ObservationIgnored
    private var dictationActive = false
    @ObservationIgnored
    private var committedDictation = ""
    @ObservationIgnored
    private var turnBeforeSubmissionID: String?
    @ObservationIgnored
    private weak var submitAfterDictationAppModel: AppModel?

    init(threadID: String) {
        self.threadID = threadID
        let dictationController = VisionDictationController()
        self.dictationController = dictationController
        dictationController.onVolatile = { [weak self] text in
            guard self?.dictationActive == true else { return }
            self?.volatileDictation = text
        }
        dictationController.onFinalized = { [weak self] text in
            self?.commitDictatedPhrase(text)
        }
        dictationController.onError = { [weak self] message in
            self?.finishDictationWithError(message)
        }
    }

    var thread: OrchestrationThread? { detail?.thread }

    var isBusy: Bool { actionState != .idle }

    var isDictating: Bool { dictationPhase != .idle }

    var isTurnRunning: Bool {
        guard let thread else { return false }
        return Self.isTurnRunning(thread)
    }

    var isAgentWorking: Bool { actionState != .idle || awaitingAgentStart || isTurnRunning }

    var workingLabel: String {
        actionState.label ?? "Agent is working"
    }

    var sessionStatus: String { thread?.session?.status ?? "not bound" }

    var turnState: String { thread?.latestTurn?.state ?? "none" }

    var activeTurnID: String? {
        guard let thread else { return nil }
        return thread.session?.activeTurnId
            ?? (thread.latestTurn?.state == "running" ? thread.latestTurn?.turnId : nil)
    }

    var transcriptRevision: String {
        let message = thread?.messages.last.map {
            "\($0.id):\($0.updatedAt):\($0.text.count):\($0.streaming)"
        } ?? "empty"
        let activity = thread?.activities.last.map {
            "\($0.id):\($0.createdAt):\($0.kind)"
        } ?? "none"
        return "\(message):\(activity):\(isAgentWorking):\(submissionRevision)"
    }

    var summarySourceRevision: String? {
        guard let thread,
              thread.messages.contains(where: {
                  $0.role == "user"
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return nil }
        let latestMessage = thread.messages.last.map {
            "\($0.id):\($0.updatedAt):\($0.text.count):\($0.streaming)"
        } ?? "none"
        let latestCheckpoint = thread.checkpoints.last.map {
            "\($0.turnId):\($0.completedAt):\($0.files.count)"
        } ?? "none"
        let latestActivity = thread.activities.last.map {
            "\($0.id):\($0.createdAt):\($0.kind)"
        } ?? "none"
        return [
            thread.updatedAt,
            latestMessage,
            latestActivity,
            latestCheckpoint,
            thread.latestTurn?.state ?? "none",
        ].joined(separator: ":")
    }

    var visibleGeneratedSummary: GeneratedTaskSummary? {
        if isAgentWorking || summaryIsLoading {
            return generatedSummary
        }
        guard generatedSummaryRevision == summarySourceRevision else { return nil }
        return generatedSummary
    }

    func start(using appModel: AppModel) async {
        guard eventsTask == nil else { return }
        loadState = .loading
        do {
            let snapshot = try await appModel.threadSnapshot(id: threadID)
            apply(snapshot)
            loadState = .loaded
            startEvents(after: snapshot.snapshotSequence, using: appModel)
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        actionTask?.cancel()
        actionTask = nil
        cancelDictation()
    }

    func ensureTaskSummary(using appModel: AppModel, force: Bool = false) async {
        guard !summaryIsLoading,
              !isAgentWorking,
              let sourceRevision = summarySourceRevision else { return }
        let cacheKey = taskSummaryCacheKey(environmentID: appModel.environment?.id)

        if !force, generatedSummaryRevision == sourceRevision, generatedSummary != nil {
            return
        }
        if !force,
           let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(CachedTaskSummary.self, from: data),
           cached.sourceRevision == sourceRevision {
            generatedSummary = cached.summary
            generatedSummaryRevision = cached.sourceRevision
            summaryError = nil
            return
        }

        summaryIsLoading = true
        defer { summaryIsLoading = false }
        summaryError = nil
        do {
            let summary = try await appModel.generateTaskSummary(threadID: threadID)
            try Task.checkCancellation()
            guard summarySourceRevision == sourceRevision else { return }
            generatedSummary = summary
            generatedSummaryRevision = sourceRevision
            if let data = try? JSONEncoder().encode(
                CachedTaskSummary(sourceRevision: sourceRevision, summary: summary)
            ) {
                UserDefaults.standard.set(data, forKey: cacheKey)
            }
        } catch is CancellationError {
            return
        } catch {
            summaryError = error.localizedDescription
        }
    }

    private func taskSummaryCacheKey(environmentID: String?) -> String {
        "codes.t3.vision.task-summary.\(environmentID ?? "unknown").\(threadID)"
    }

    func submit(using appModel: AppModel) {
        guard actionTask == nil else {
            actionError = "Another thread action is already in progress."
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            actionError = "Type a message before sending."
            return
        }

        let optimisticDraft = draft
        draft = ""
        submissionRevision &+= 1
        turnBeforeSubmissionID = thread?.latestTurn?.turnId
        awaitingAgentStart = true
        actionState = isTurnRunning ? .requestingInterrupt : .sending

        actionTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            await performSend(
                text: text,
                restoringOnFailure: optimisticDraft,
                using: appModel
            )
            actionTask = nil
        }
    }

    /// Always dispatches. The UI intentionally does not gate Stop on a cached
    /// session status; stale guards are how the existing client silently no-ops.
    func interrupt(using appModel: AppModel) {
        guard actionTask == nil else {
            actionError = "Another thread action is already in progress."
            return
        }
        actionTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            await performInterrupt(using: appModel)
            actionTask = nil
        }
    }

    func beginDictation(vocabulary: [String]) {
        guard !isBusy else {
            dictationError = "Wait for the current thread action to finish."
            return
        }
        guard !dictationActive else { return }

        dictationActive = true
        committedDictation = ""
        volatileDictation = ""
        dictationError = nil
        dictationPhase = .preparing
        dictationTask = Task { [weak self] in
            guard let self else { return }
            let granted = await VisionDictationController.requestPermission()
            guard !Task.isCancelled, dictationActive else { return }
            guard granted else {
                finishDictationWithError(
                    VisionDictationError.microphonePermissionDenied.localizedDescription
                )
                return
            }
            do {
                try await dictationController.start(contextualStrings: vocabulary)
                guard dictationActive else {
                    await dictationController.cancel()
                    return
                }
                if dictationPhase == .preparing { dictationPhase = .listening }
            } catch is CancellationError {
                return
            } catch {
                finishDictationWithError(error.localizedDescription)
            }
        }
    }

    func finishDictation() {
        finishDictation(submitUsing: nil)
    }

    func finishDictationAndSubmit(using appModel: AppModel) {
        finishDictation(submitUsing: appModel)
    }

    private func finishDictation(submitUsing appModel: AppModel?) {
        if let appModel {
            submitAfterDictationAppModel = appModel
        }
        guard dictationActive else {
            if let submitAfterDictationAppModel {
                self.submitAfterDictationAppModel = nil
                submit(using: submitAfterDictationAppModel)
            }
            return
        }
        guard dictationPhase != .finishing else { return }
        dictationPhase = .finishing
        let preparationTask = dictationTask
        dictationTask = Task { [weak self] in
            guard let self else { return }
            await preparationTask?.value
            guard dictationActive else { return }
            await dictationController.finish()
            dictationActive = false
            volatileDictation = ""
            committedDictation = ""
            dictationPhase = .idle
            dictationTask = nil
            if let submitAfterDictationAppModel {
                self.submitAfterDictationAppModel = nil
                submit(using: submitAfterDictationAppModel)
            }
        }
    }

    func cancelDictation() {
        guard dictationActive || dictationPhase != .idle else { return }
        dictationActive = false
        dictationTask?.cancel()
        dictationTask = Task { [weak self] in
            await self?.dictationController.cancel()
        }
        volatileDictation = ""
        dictationPhase = .idle
        submitAfterDictationAppModel = nil

        if !committedDictation.isEmpty, draft.hasSuffix(committedDictation) {
            draft.removeLast(committedDictation.count)
        }
        committedDictation = ""
    }

    private func startEvents(after sequence: Int, using appModel: AppModel) {
        eventsTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            do {
                let stream = try await appModel.threadEvents(
                    threadID: threadID,
                    after: sequence
                )
                for try await item in stream {
                    try Task.checkCancellation()
                    switch item {
                    case .synchronized:
                        liveError = nil
                    case let .snapshot(snapshot):
                        apply(snapshot)
                    case .event:
                        scheduleRefresh(using: appModel)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                liveError = "Live updates paused: \(error.localizedDescription)"
            }
        }
    }

    /// The stream carries compact domain events rather than rebuilt threads.
    /// Coalesce token and tool bursts into authoritative detail reads so this
    /// small client stays correct without duplicating the upstream reducer.
    private func scheduleRefresh(using appModel: AppModel) {
        refreshGeneration &+= 1
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            while !Task.isCancelled {
                let targetGeneration = refreshGeneration
                do {
                    try await Task.sleep(for: .milliseconds(80))
                    try Task.checkCancellation()
                    let snapshot = try await appModel.threadSnapshot(id: threadID)
                    apply(snapshot)
                    liveError = nil
                } catch is CancellationError {
                    return
                } catch {
                    liveError = "Could not refresh this thread: \(error.localizedDescription)"
                }

                guard targetGeneration != refreshGeneration else {
                    refreshTask = nil
                    return
                }
            }
        }
    }

    private func apply(_ snapshot: OrchestrationThreadDetailSnapshot) {
        guard snapshot.snapshotSequence >= (detail?.snapshotSequence ?? 0) else { return }
        detail = snapshot
        if awaitingAgentStart,
           snapshot.thread.latestTurn?.turnId != turnBeforeSubmissionID {
            awaitingAgentStart = false
            turnBeforeSubmissionID = nil
        }
    }

    private func commitDictatedPhrase(_ phrase: String) {
        guard dictationActive else { return }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        let appended = separator + trimmed
        draft += appended
        committedDictation += appended
        volatileDictation = ""
    }

    private func finishDictationWithError(_ message: String) {
        dictationActive = false
        dictationPhase = .idle
        volatileDictation = ""
        dictationError = message
    }

    private func performSend(
        text: String,
        restoringOnFailure optimisticDraft: String,
        using appModel: AppModel
    ) async {
        defer { actionState = .idle }
        actionError = nil
        actionNotice = nil
        do {
            guard var currentThread = thread else { throw ActionError.threadUnavailable }
            let steering = Self.isTurnRunning(currentThread)

            if steering {
                let targetTurnID = activeTurnID
                let knownInterruptFailures = Self.interruptFailureIDs(in: currentThread)
                actionState = .requestingInterrupt
                let dispatch = try await appModel.interrupt(
                    threadID: threadID,
                    turnID: targetTurnID
                )
                actionNotice = "Interrupt dispatched at event \(dispatch.sequence)."
                actionState = .waitingForInterruption
                let settlement = try await waitForSettlement(
                    targetTurnID: targetTurnID,
                    after: dispatch.sequence,
                    ignoringFailureIDs: knownInterruptFailures,
                    using: appModel
                )
                switch settlement {
                case .interrupted:
                    actionNotice = "Turn interrupted. Sending the redirect now."
                case let .alreadySettled(state):
                    actionNotice = "The old turn is terminal (\(state)). Sending the redirect now."
                }
                currentThread = thread ?? currentThread
                actionState = .sendingRedirect
            } else {
                actionState = .sending
            }

            _ = try await appModel.sendTurn(thread: currentThread, text: text)
            actionNotice = nil
            scheduleRefresh(using: appModel)
        } catch is CancellationError {
            return
        } catch {
            awaitingAgentStart = false
            turnBeforeSubmissionID = nil
            if draft.isEmpty {
                draft = optimisticDraft
                draftRestorationRevision &+= 1
            }
            actionError = error.localizedDescription
        }
    }

    private func performInterrupt(using appModel: AppModel) async {
        defer { actionState = .idle }
        actionError = nil
        actionNotice = nil
        do {
            let targetTurnID = activeTurnID
            let knownInterruptFailures = Self.interruptFailureIDs(in: thread)
            actionState = .requestingInterrupt
            let dispatch = try await appModel.interrupt(
                threadID: threadID,
                turnID: targetTurnID
            )
            actionNotice = "Interrupt dispatched at event \(dispatch.sequence)."
            actionState = .waitingForInterruption
            let settlement = try await waitForSettlement(
                targetTurnID: targetTurnID,
                after: dispatch.sequence,
                ignoringFailureIDs: knownInterruptFailures,
                using: appModel
            )
            switch settlement {
            case .interrupted:
                actionNotice = "Turn interrupted."
            case let .alreadySettled(state):
                actionNotice = "Interrupt was dispatched; the server reports \(state)."
            }
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// The interrupt command only means the request was persisted. A redirect
    /// cannot be sent until the thread stream proves the old turn is terminal,
    /// otherwise it would reproduce the queueing behavior this client exists to fix.
    private func waitForSettlement(
        targetTurnID: String?,
        after interruptSequence: Int,
        ignoringFailureIDs: Set<String>,
        using appModel: AppModel
    ) async throws -> TurnSettlement {
        let initial = try await appModel.threadSnapshot(id: threadID)
        apply(initial)
        try Self.checkInterruptFailure(
            in: initial.thread,
            ignoring: ignoringFailureIDs
        )
        if let settlement = Self.settlement(
            of: initial.thread,
            targetTurnID: targetTurnID
        ) {
            return settlement
        }

        let resumeSequence = max(interruptSequence, initial.snapshotSequence)
        let stream = try await appModel.threadEvents(
            threadID: threadID,
            after: resumeSequence
        )
        for try await item in stream {
            try Task.checkCancellation()
            let snapshot: OrchestrationThreadDetailSnapshot?
            switch item {
            case .synchronized:
                snapshot = nil
            case let .snapshot(replacement):
                snapshot = replacement
            case .event:
                snapshot = try await appModel.threadSnapshot(id: threadID)
            }
            guard let snapshot else { continue }
            apply(snapshot)
            try Self.checkInterruptFailure(
                in: snapshot.thread,
                ignoring: ignoringFailureIDs
            )
            if let settlement = Self.settlement(
                of: snapshot.thread,
                targetTurnID: targetTurnID
            ) {
                return settlement
            }
        }
        throw ActionError.eventStreamEnded
    }

    private static func isTurnRunning(_ thread: OrchestrationThread) -> Bool {
        thread.session?.status == "starting"
            || thread.session?.status == "running"
            || thread.latestTurn?.state == "running"
    }

    private static func settlement(
        of thread: OrchestrationThread,
        targetTurnID: String?
    ) -> TurnSettlement? {
        if let targetTurnID {
            if thread.latestTurn?.turnId == targetTurnID {
                switch thread.latestTurn?.state {
                case "interrupted":
                    return .interrupted
                case "completed", "error":
                    return .alreadySettled(thread.latestTurn?.state ?? "finished")
                default:
                    break
                }
            }
            guard thread.session?.activeTurnId != targetTurnID,
                  !isTurnRunning(thread) else { return nil }
        } else {
            guard !isTurnRunning(thread) else { return nil }
        }

        if thread.session?.status == "interrupted" || thread.latestTurn?.state == "interrupted" {
            return .interrupted
        }
        return .alreadySettled(thread.session?.status ?? thread.latestTurn?.state ?? "idle")
    }

    private static func interruptFailureIDs(in thread: OrchestrationThread?) -> Set<String> {
        Set(
            (thread?.activities ?? [])
                .filter { $0.kind == "provider.turn.interrupt.failed" }
                .map(\.id)
        )
    }

    private static func checkInterruptFailure(
        in thread: OrchestrationThread,
        ignoring knownIDs: Set<String>
    ) throws {
        guard let failure = thread.activities.last(where: {
            $0.kind == "provider.turn.interrupt.failed" && !knownIDs.contains($0.id)
        }) else { return }
        throw ActionError.interruptFailed(
            failure.payload["detail"]?.stringValue ?? failure.summary
        )
    }
}

private enum TranscriptEntry: Identifiable {
    case message(OrchestrationMessage)
    case activity(OrchestrationActivity)

    var id: String {
        switch self {
        case let .message(message): "message:\(message.id)"
        case let .activity(activity): "activity:\(activity.id)"
        }
    }

    var createdAt: String {
        switch self {
        case let .message(message): message.createdAt
        case let .activity(activity): activity.createdAt
        }
    }
}

private enum TaskDetailMode: String, Hashable {
    case summary
    case chat
}

private struct TaskAttentionItem: Identifiable {
    enum Kind {
        case approval
        case input
        case plan
        case error
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let createdAt: String
}

private func userInputSummary(_ payload: JSONValue) -> String? {
    guard case let .array(questions)? = payload["questions"] else { return nil }
    let summaries = questions.compactMap { value -> String? in
        guard case let .object(question) = value,
              let text = question["question"]?.stringValue else { return nil }
        guard case let .array(options)? = question["options"] else { return text }
        let choices = options.compactMap { option -> String? in
            guard case let .object(fields) = option,
                  let label = fields["label"]?.stringValue else { return nil }
            guard let description = fields["description"]?.stringValue,
                  !description.isEmpty else { return label }
            return "\(label) — \(description)"
        }
        guard !choices.isEmpty else { return text }
        return "\(text)\nOptions: \(choices.joined(separator: "; "))"
    }
    guard !summaries.isEmpty else { return nil }
    return summaries.joined(separator: "\n\n")
}

private struct VoiceDockHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ThreadDetailView: View {
    private enum DraftEditorMode {
        case hidden
        case softwareKeyboard
        case hardwareKeyboard
    }

    @SwiftUI.Environment(AppModel.self) private var appModel
    private let detailModeDefaultsKey: String
    @State private var model: ThreadDetailModel
    @State private var detailMode: TaskDetailMode
    @State private var draftEditorMode = DraftEditorMode.hidden
    @State private var prefersHardwareEditor = false
    @State private var dictationBaseline = ""
    @State private var microphoneHovered = false
    @State private var voiceDockHeight: CGFloat = 0

    init(threadID: String) {
        let detailModeDefaultsKey = "codes.t3.vision.task-detail-mode.\(threadID)"
        self.detailModeDefaultsKey = detailModeDefaultsKey
        _model = State(initialValue: ThreadDetailModel(threadID: threadID))
        _detailMode = State(
            initialValue: UserDefaults.standard.string(forKey: detailModeDefaultsKey)
                .flatMap(TaskDetailMode.init(rawValue:))
                ?? .summary
        )
    }

    var body: some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView("Loading thread…")
            case let .failed(message):
                ContentUnavailableView {
                    Label("Could not load thread", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded:
                taskDetail
            }
        }
        .navigationTitle("")
        .task { await model.start(using: appModel) }
        .onChange(of: model.isDictating) {
            if !model.isDictating, model.draft != dictationBaseline {
                prefersHardwareEditor = true
                draftEditorMode = .hardwareKeyboard
            }
        }
        .onChange(of: model.submissionRevision) {
            draftEditorMode = .hidden
        }
        .onChange(of: model.draftRestorationRevision) {
            draftEditorMode = prefersHardwareEditor ? .hardwareKeyboard : .softwareKeyboard
        }
        .onChange(of: detailMode) {
            UserDefaults.standard.set(detailMode.rawValue, forKey: detailModeDefaultsKey)
        }
        .onDisappear { model.stop() }
    }

    private var taskDetail: some View {
        VStack(spacing: 0) {
            threadStateBar
            Divider()

            switch detailMode {
            case .summary:
                taskSummary
            case .chat:
                chatTranscript
            }

            Divider()
            voiceDock
        }
    }

    private var chatTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let error = model.liveError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }

                    ForEach(transcriptEntries) { entry in
                        switch entry {
                        case let .message(message):
                            MessageBubble(message: message)
                        case let .activity(activity):
                            ActivityRow(activity: activity)
                        }
                    }

                    if model.isAgentWorking {
                        AgentWorkingRow(label: model.workingLabel)
                            .id("\(model.threadID)-working")
                    }

                    Color.clear
                        .frame(height: 12)
                        .id(transcriptBottomID)
                }
                .padding(20)
            }
            .onChange(of: model.transcriptRevision) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
            }
            .task(id: voiceDockHeight) {
                guard voiceDockHeight > 0 else { return }
                await Task.yield()
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
            }
            .task(id: model.thread?.id) {
                await Task.yield()
                proxy.scrollTo(transcriptBottomID, anchor: .bottom)
            }
        }
    }

    private var taskSummary: some View {
        let pendingAttention = attentionItems
        let generatedActions = pendingAttention.isEmpty
            && !model.isAgentWorking
            && model.generatedSummaryRevision == model.summarySourceRevision
            ? model.visibleGeneratedSummary?.needsYou ?? []
            : []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let error = model.liveError {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                taskSummaryGenerationStatus

                if !pendingAttention.isEmpty || !generatedActions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Needs you", systemImage: "exclamationmark.bubble.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        ForEach(pendingAttention) { item in
                            TaskAttentionCard(item: item) {
                                detailMode = .chat
                            }
                        }

                        ForEach(Array(generatedActions.enumerated()), id: \.offset) { _, action in
                            TaskSummaryActionCard(action: action)
                        }
                    }
                }

                TaskBriefCard(
                    title: "What you asked",
                    icon: "text.bubble",
                    text: model.visibleGeneratedSummary?.asked
                        ?? (model.summaryError == nil ? nil : originalRequest),
                    emptyText: model.summaryIsLoading
                        ? "Generating an AI brief…"
                        : "The task request has not arrived yet.",
                    isWorking: false,
                    files: []
                )

                TaskBriefCard(
                    title: "What was done",
                    icon: "checkmark.circle",
                    text: model.visibleGeneratedSummary?.done
                        ?? (model.summaryError == nil ? nil : latestResult),
                    emptyText: model.summaryIsLoading
                        ? "Reading the task history…"
                        : (model.isAgentWorking
                            ? "The agent is working on this now."
                            : "The agent has not returned a result yet."),
                    isWorking: model.isAgentWorking,
                    files: latestCheckpointFiles
                )

                if pendingAttention.isEmpty && generatedActions.isEmpty {
                    Label(
                        model.isAgentWorking
                            ? "Nothing needs your input while the agent works."
                            : "No decision or action is waiting on you.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .task(id: "\(model.summarySourceRevision ?? "none"):\(model.isAgentWorking)") {
            await model.ensureTaskSummary(using: appModel)
        }
    }

    @ViewBuilder
    private var taskSummaryGenerationStatus: some View {
        HStack(spacing: 10) {
            if model.summaryIsLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.visibleGeneratedSummary == nil
                        ? "AI task brief"
                        : "AI-generated task brief"
                )
                    .font(.caption.weight(.semibold))
                if let summary = model.visibleGeneratedSummary {
                    Text("\(summary.modelSelection.instanceId) · \(summary.modelSelection.model)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if model.summaryIsLoading {
                    Text("Using the text-generation model configured on the server")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await model.ensureTaskSummary(using: appModel, force: true) }
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .disabled(model.summaryIsLoading || model.isAgentWorking)
            .accessibilityLabel("Regenerate AI task brief")
        }

        if model.isAgentWorking, model.visibleGeneratedSummary != nil {
            Text("This brief will refresh when the current turn finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let error = model.summaryError {
            Label(
                model.visibleGeneratedSummary == nil
                    ? "AI summary unavailable. Showing transcript excerpts instead. \(error)"
                    : "Could not refresh the AI summary. Keeping the previous brief. \(error)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var threadStateBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let projectTitle {
                    Text(projectTitle.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Text(model.thread?.title ?? "Task")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let label = model.actionState.label {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                            .fontWeight(.semibold)
                        Text(label)
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                } else if model.isTurnRunning {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                            .fontWeight(.semibold)
                        Text("Agent is working")
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                } else {
                    Text("Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Task view", selection: $detailMode) {
                Text("Summary").tag(TaskDetailMode.summary)
                Text("Chat").tag(TaskDetailMode.chat)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityHint("The selected view is remembered for this task")
            if model.isTurnRunning {
                Button(role: .destructive) {
                    model.interrupt(using: appModel)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .foregroundStyle(.white)
                .disabled(model.isBusy)
                .accessibilityHint("Dispatches an interrupt using the latest known turn ID")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var voiceDock: some View {
        @Bindable var model = model
        return VStack(spacing: 12) {
            if let error = model.dictationError ?? model.actionError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let label = model.dictationPhase.label {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.caption.weight(.semibold))
                        if !model.volatileDictation.isEmpty {
                            Text(model.volatileDictation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        model.cancelDictation()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .foregroundStyle(.white)
                }
            } else if let notice = model.actionNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.isDictating, !voicePreview.isEmpty {
                Text(voicePreview)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if draftEditorMode != .hidden {
                HStack(alignment: .top, spacing: 8) {
                    if draftEditorMode == .hardwareKeyboard {
                        ZStack(alignment: .topLeading) {
                            if model.draft.isEmpty {
                                Text(messagePrompt)
                                    .foregroundStyle(.tertiary)
                                    .allowsHitTesting(false)
                            }
                            HardwareKeyboardDraftEditor(text: $model.draft)
                        }
                        .frame(minHeight: 24, idealHeight: 52, maxHeight: 88)
                    } else {
                        TextField(
                            messagePrompt,
                            text: $model.draft,
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                    }

                    if !model.draft.isEmpty {
                        Button {
                            model.draft = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear message")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(model.isBusy)
            }

            HStack(alignment: .center, spacing: 18) {
                Button {
                    if draftEditorMode == .hidden {
                        draftEditorMode = prefersHardwareEditor
                            ? .hardwareKeyboard
                            : .softwareKeyboard
                    } else {
                        draftEditorMode = .hidden
                    }
                } label: {
                    Image(
                        systemName: draftEditorMode == .hidden
                            ? "keyboard"
                            : "keyboard.chevron.compact.down"
                    )
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(
                    draftEditorMode == .hidden ? "Show message editor" : "Hide message editor"
                )

                dictationButton

                Button {
                    if model.isDictating {
                        model.finishDictationAndSubmit(using: appModel)
                    } else {
                        model.submit(using: appModel)
                    }
                } label: {
                    Label("Send", systemImage: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 96, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.blue)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(
                    model.isBusy
                        || (!model.isDictating
                            && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
            }

        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: VoiceDockHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
        .onPreferenceChange(VoiceDockHeightPreferenceKey.self) {
            voiceDockHeight = $0
        }
    }

    private var dictationButton: some View {
        Button {
            if model.isDictating {
                model.finishDictation()
            } else {
                dictationBaseline = model.draft
                draftEditorMode = .hidden
                model.beginDictation(vocabulary: appModel.dictationVocabulary)
            }
        } label: {
            Image(systemName: model.isDictating ? "stop.fill" : "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(microphoneColor, in: Circle())
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
        .animation(.easeOut(duration: 0.12), value: model.isDictating)
        .opacity(model.isBusy ? 0.4 : 1)
        .disabled(model.isBusy)
        .accessibilityLabel(model.isDictating ? "Stop dictation" : "Start dictation")
    }

    private var microphoneColor: Color {
        if model.isDictating { return .red }
        if microphoneHovered { return .green }
        return Color.secondary.opacity(0.45)
    }

    private var messagePrompt: String {
        model.isTurnRunning ? "Redirect the running agent…" : "Message the agent…"
    }

    private var transcriptBottomID: String {
        "\(model.threadID)-transcript-bottom"
    }

    private var transcriptEntries: [TranscriptEntry] {
        let messages = (model.thread?.messages ?? []).map(TranscriptEntry.message)
        let activities = visibleActivities.map(TranscriptEntry.activity)
        return (messages + activities).sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    private var originalRequest: String? {
        let requests = model.thread?.messages.filter {
            $0.role == "user"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        guard let original = requests.first else { return nil }
        let originalText = conciseText(original.text, limit: 800)
        guard let latest = requests.last, latest.id != original.id else { return originalText }
        return "\(originalText)\n\nLatest direction\n\(conciseText(latest.text, limit: 400))"
    }

    private var latestResult: String? {
        model.thread?.messages.last(where: {
            $0.role == "assistant"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }).map { conciseText($0.text) }
    }

    private var latestCheckpointFiles: [CheckpointFile] {
        guard let checkpoints = model.thread?.checkpoints else { return [] }
        if let latestTurnID = model.thread?.latestTurn?.turnId,
           let checkpoint = checkpoints.last(where: { $0.turnId == latestTurnID }) {
            return checkpoint.files
        }
        return checkpoints.last?.files ?? []
    }

    private var attentionItems: [TaskAttentionItem] {
        guard let thread = model.thread else { return [] }
        var open: [String: TaskAttentionItem] = [:]
        for activity in thread.activities.sorted(by: {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }) {
            guard let requestID = activity.payload["requestId"]?.stringValue else { continue }
            switch activity.kind {
            case "approval.requested":
                let key = "approval:\(requestID)"
                open[key] = TaskAttentionItem(
                    id: key,
                    kind: .approval,
                    title: activity.summary,
                    detail: activity.payload["detail"]?.stringValue ?? "Review this approval request.",
                    createdAt: activity.createdAt
                )
            case "user-input.requested":
                let key = "input:\(requestID)"
                open[key] = TaskAttentionItem(
                    id: key,
                    kind: .input,
                    title: activity.summary,
                    detail: userInputSummary(activity.payload) ?? "The agent is waiting for your input.",
                    createdAt: activity.createdAt
                )
            case "approval.resolved":
                open["approval:\(requestID)"] = nil
            case "user-input.resolved":
                open["input:\(requestID)"] = nil
            case "provider.approval.respond.failed":
                let detail = activity.payload["detail"]?.stringValue?.lowercased() ?? ""
                if detail.contains("stale") || detail.contains("unknown") {
                    open["approval:\(requestID)"] = nil
                }
            case "provider.user-input.respond.failed":
                let detail = activity.payload["detail"]?.stringValue?.lowercased() ?? ""
                if detail.contains("stale") || detail.contains("unknown") {
                    open["input:\(requestID)"] = nil
                }
            default:
                break
            }
        }

        var items = open.values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
        if currentThreadShell?.hasActionableProposedPlan == true {
            items.append(
                TaskAttentionItem(
                    id: "proposed-plan",
                    kind: .plan,
                    title: "Plan ready for review",
                    detail: "Review the proposed plan before the agent starts implementation.",
                    createdAt: thread.updatedAt
                )
            )
        }
        if thread.latestTurn?.state == "error",
           let error = thread.activities.last(where: { $0.tone == "error" }) {
            items.append(
                TaskAttentionItem(
                    id: "error:\(error.id)",
                    kind: .error,
                    title: error.summary,
                    detail: error.payload["detail"]?.stringValue
                        ?? error.payload["message"]?.stringValue
                        ?? "The latest turn failed and may need a redirect or retry.",
                    createdAt: error.createdAt
                )
            )
        }
        return items
    }

    private var currentThreadShell: OrchestrationThreadShell? {
        appModel.snapshot?.threads.first { $0.id == model.threadID }
            ?? appModel.archivedThreads.first { $0.id == model.threadID }
    }

    private func conciseText(_ text: String, limit: Int = 1_200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private var visibleActivities: [OrchestrationActivity] {
        let activities = model.thread?.activities ?? []
        let completedTools = Set(
            activities
                .filter { $0.kind == "tool.completed" }
                .map { activityCorrelationKey($0) }
        )
        return activities.filter { activity in
            if activity.tone == "error" || activity.tone == "approval" { return true }
            if activity.kind == "user-input.requested"
                || activity.kind == "user-input.resolved" { return true }
            guard activity.tone == "tool" else { return false }
            switch activity.kind {
            case "tool.completed":
                return true
            case "tool.started":
                return !completedTools.contains(activityCorrelationKey(activity))
            default:
                return false
            }
        }
    }

    private func activityCorrelationKey(_ activity: OrchestrationActivity) -> String {
        let itemType = activity.payload["itemType"]?.stringValue ?? "tool"
        let normalizedSummary = activity.summary.replacingOccurrences(
            of: #"\s+started$"#,
            with: "",
            options: .regularExpression
        )
        let detail = activity.payload["detail"]?.stringValue ?? normalizedSummary
        return "\(activity.turnId ?? "thread"):\(itemType):\(detail)"
    }

    private var projectTitle: String? {
        guard let projectID = model.thread?.projectId else { return nil }
        return appModel.snapshot?.projects.first { $0.id == projectID }?.title
    }

    private var voicePreview: String {
        let committed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = model.volatileDictation.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return volatile }
        if volatile.isEmpty { return committed }
        return "\(committed) \(volatile)"
    }
}

private final class HardwareKeyboardTextView: UITextView {
    private let suppressedSoftwareKeyboard = UIView(frame: .zero)

    override var inputView: UIView? {
        get { suppressedSoftwareKeyboard }
        set {}
    }
}

private struct HardwareKeyboardDraftEditor: UIViewRepresentable {
    @SwiftUI.Environment(\.isEnabled) private var isEnabled
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = HardwareKeyboardTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
        }
        view.isEditable = isEnabled
        view.isSelectable = true
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.resignFirstResponder()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

private struct ActivityRow: View {
    let activity: OrchestrationActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if detail == nil {
                header
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        expanded.toggle()
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(summary), \(expanded ? "collapse" : "expand") details")
            }

            if expanded, let detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 27)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(iconColor)
            Text(summary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if detail != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }

    private var summary: String {
        activity.summary.replacingOccurrences(
            of: #"\s+started$"#,
            with: "",
            options: .regularExpression
        )
    }

    private var icon: String {
        if activity.tone == "error" { return "exclamationmark.triangle.fill" }
        if activity.tone == "approval" { return "hand.raised.fill" }
        if activity.kind == "user-input.requested" { return "questionmark.bubble.fill" }
        if activity.kind == "user-input.resolved" { return "checkmark.bubble.fill" }
        if activity.kind == "tool.started" { return "ellipsis" }
        return switch activity.payload["itemType"]?.stringValue {
        case "command_execution": "terminal"
        case "file_change": "doc.badge.gearshape"
        case "mcp_tool_call": "wrench.and.screwdriver"
        case "web_search": "globe"
        case "image_generation": "photo"
        default: "gearshape.2"
        }
    }

    private var iconColor: Color {
        switch activity.tone {
        case "error": .red
        case "approval": .orange
        default: .secondary
        }
    }

    private var detail: String? {
        if activity.kind == "user-input.requested" {
            return userInputSummary(activity.payload)
        }
        return activity.payload["detail"]?.stringValue
            ?? activity.payload["message"]?.stringValue
    }
}

private struct TaskBriefCard: View {
    let title: String
    let icon: String
    let text: String?
    let emptyText: String
    let isWorking: Bool
    let files: [CheckpointFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.headline)
                Spacer()
                if isWorking {
                    Text("In progress")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }

            Text(text ?? emptyText)
                .foregroundStyle(text == nil ? .secondary : .primary)
                .textSelection(.enabled)

            if !files.isEmpty {
                Divider()
                Label(
                    "\(files.count) changed \(files.count == 1 ? "file" : "files")",
                    systemImage: "doc.badge.gearshape"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(Array(files.prefix(6).enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 8) {
                        Text(file.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("+\(file.additions) −\(file.deletions)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if files.count > 6 {
                    Text("+ \(files.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TaskAttentionCard: View {
    let item: TaskAttentionItem
    let showChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(item.title, systemImage: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
            Text(item.detail)
                .font(.callout)
                .textSelection(.enabled)
            Button("View in chat", action: showChat)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: String {
        switch item.kind {
        case .approval: "hand.raised.fill"
        case .input: "questionmark.bubble.fill"
        case .plan: "list.bullet.rectangle"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .error: .red
        default: .orange
        }
    }
}

private struct TaskSummaryActionCard: View {
    let action: String

    var body: some View {
        Label {
            Text(action)
                .font(.callout)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "questionmark.circle.fill")
        }
        .foregroundStyle(.orange)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AgentWorkingRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
            Text(label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.09))
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(label)
    }
}

private struct MessageBubble: View {
    let message: OrchestrationMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(message.role.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if message.streaming {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Streaming")
                }
            }

            if message.text.isEmpty {
                Text(message.streaming ? "Thinking…" : "No text")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(message.text)
                    .textSelection(.enabled)
            }

            if let attachments = message.attachments, !attachments.isEmpty {
                ForEach(attachments) { attachment in
                    Label(attachment.name, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
