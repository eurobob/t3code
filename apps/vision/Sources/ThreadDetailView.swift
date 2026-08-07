import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class ThreadDetailModel {
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

    enum ScriptActionState: Equatable {
        case idle
        case starting
        case running
        case succeeded
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .starting, .running: true
            case .idle, .succeeded, .failed: false
            }
        }

        var label: String {
            switch self {
            case .idle: "Ready"
            case .starting: "Opening terminal…"
            case .running: "Running…"
            case .succeeded: "Finished successfully"
            case let .failed(message): message
            }
        }

        var systemImage: String {
            switch self {
            case .idle: "terminal"
            case .starting, .running: "ellipsis"
            case .succeeded: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
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

    private enum ScriptError: LocalizedError {
        case threadUnavailable
        case terminalStreamEnded
        case terminalClosed
        case terminalFailed(String)

        var errorDescription: String? {
            switch self {
            case .threadUnavailable:
                "The thread state is not available yet."
            case .terminalStreamEnded:
                "Terminal output stopped before the deploy command finished."
            case .terminalClosed:
                "The terminal closed before the deploy command finished."
            case let .terminalFailed(message):
                message
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
    private(set) var scriptActionState: ScriptActionState = .idle
    private(set) var activeScriptName: String?
    private(set) var scriptOutput = ""
    private(set) var scriptOutputWasTruncated = false
    private(set) var submissionRevision = 0
    private(set) var draftRestorationRevision = 0
    private(set) var awaitingAgentStart = false
    var draft = ""

    @ObservationIgnored
    private var eventsTask: Task<Void, Never>?
    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var actionTask: Task<Void, Never>?
    @ObservationIgnored
    private var scriptTask: Task<Void, Never>?
    @ObservationIgnored
    private var scriptCompletionMarker: String?
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

    var isScriptRunning: Bool { scriptActionState.isRunning }

    var visibleScriptOutput: String {
        let normalized = scriptOutput
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let visible = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard let scriptCompletionMarker else { return true }
                return !line.contains(scriptCompletionMarker)
            }
            .joined(separator: "\n")
        guard scriptOutputWasTruncated else { return visible }
        return "[Earlier terminal output omitted]\n\(visible)"
    }

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

    func runScript(
        _ script: ProjectScript,
        project: OrchestrationProject,
        using appModel: AppModel
    ) {
        guard scriptTask == nil else { return }
        guard let thread else {
            scriptActionState = .failed(
                ScriptError.threadUnavailable.localizedDescription
            )
            return
        }

        activeScriptName = script.name
        scriptActionState = .starting
        scriptOutput = ""
        scriptOutputWasTruncated = false
        let marker = "__T3_VISION_SCRIPT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__:"
        scriptCompletionMarker = marker

        scriptTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            await performScript(
                script,
                project: project,
                thread: thread,
                completionMarker: marker,
                using: appModel
            )
            scriptTask = nil
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

    private func performScript(
        _ script: ProjectScript,
        project: OrchestrationProject,
        thread: OrchestrationThread,
        completionMarker: String,
        using appModel: AppModel
    ) async {
        let terminalID = "vision-script-\(UUID().uuidString.lowercased())"
        let worktreePath = thread.worktreePath
        let cwd = worktreePath ?? project.workspaceRoot
        var environmentVariables = [
            "T3CODE_PROJECT_ROOT": project.workspaceRoot,
        ]
        if let worktreePath {
            environmentVariables["T3CODE_WORKTREE_PATH"] = worktreePath
        }
        var terminalOpened = false

        do {
            let opened = try await appModel.openTerminal(
                threadID: thread.id,
                terminalID: terminalID,
                cwd: cwd,
                worktreePath: worktreePath,
                environmentVariables: environmentVariables
            )
            terminalOpened = true
            replaceScriptOutput(with: opened.history)

            let stream = try await appModel.attachTerminal(
                threadID: thread.id,
                terminalID: terminalID
            )
            var iterator = stream.makeAsyncIterator()
            guard let initial = try await iterator.next() else {
                throw ScriptError.terminalStreamEnded
            }
            if let snapshot = initial.snapshot {
                replaceScriptOutput(with: snapshot.history)
            } else if initial.type == "error" {
                throw ScriptError.terminalFailed(
                    initial.message ?? "The terminal could not start."
                )
            }

            // The exit marker makes even an immediate guard failure observable;
            // subprocess activity polling alone can miss commands shorter than
            // its one-second interval.
            let completionCommand =
                "printf '\\n\(completionMarker)%s\\n' \"$?\""
            try await appModel.writeTerminal(
                threadID: thread.id,
                terminalID: terminalID,
                data: "\(script.command)\r\(completionCommand)\r"
            )
            scriptActionState = .running

            var completed = false
            while let event = try await iterator.next() {
                if let eventThreadID = event.threadId,
                   let eventTerminalID = event.terminalId,
                   (eventThreadID != thread.id || eventTerminalID != terminalID) {
                    continue
                }

                switch event.type {
                case "snapshot", "started", "restarted":
                    if let snapshot = event.snapshot {
                        replaceScriptOutput(with: snapshot.history)
                    }
                case "output":
                    if let data = event.data {
                        appendScriptOutput(data)
                    }
                case "cleared":
                    scriptOutput = ""
                    scriptOutputWasTruncated = false
                case "error":
                    throw ScriptError.terminalFailed(
                        event.message ?? "The terminal reported an error."
                    )
                case "closed", "exited":
                    throw ScriptError.terminalClosed
                default:
                    break
                }

                if let exitCode = scriptExitCode(
                    in: scriptOutput,
                    completionMarker: completionMarker
                ) {
                    scriptActionState = exitCode == 0
                        ? .succeeded
                        : .failed("Command exited with status \(exitCode).")
                    completed = true
                    break
                }
            }
            if !completed {
                throw ScriptError.terminalStreamEnded
            }
        } catch is CancellationError {
            scriptActionState = .failed("Terminal output monitoring was cancelled.")
        } catch {
            scriptActionState = .failed(error.localizedDescription)
        }

        if terminalOpened {
            try? await appModel.closeTerminal(
                threadID: thread.id,
                terminalID: terminalID
            )
        }
    }

    private func replaceScriptOutput(with output: String) {
        scriptOutput = ""
        scriptOutputWasTruncated = false
        appendScriptOutput(output)
    }

    private func appendScriptOutput(_ output: String) {
        scriptOutput.append(contentsOf: output)
        guard scriptOutput.count > 200_000 else { return }
        scriptOutput = String(scriptOutput.suffix(160_000))
        scriptOutputWasTruncated = true
    }

    private func scriptExitCode(
        in output: String,
        completionMarker: String
    ) -> Int? {
        var searchStart = output.startIndex
        while searchStart < output.endIndex,
              let markerRange = output.range(
                  of: completionMarker,
                  range: searchStart..<output.endIndex
              ) {
            let suffix = output[markerRange.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if !digits.isEmpty, let exitCode = Int(String(digits)) {
                return exitCode
            }
            searchStart = markerRange.upperBound
        }
        return nil
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
    case activityBatch([OrchestrationActivity])

    var id: String {
        switch self {
        case let .message(message): "message:\(message.id)"
        case let .activity(activity): "activity:\(activity.id)"
        case let .activityBatch(activities):
            "activity-batch:\(activities.first?.id ?? "empty"):\(activities.last?.id ?? "empty")"
        }
    }

    var createdAt: String {
        switch self {
        case let .message(message): message.createdAt
        case let .activity(activity): activity.createdAt
        case let .activityBatch(activities): activities.first?.createdAt ?? ""
        }
    }
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
    @State private var model: ThreadDetailModel
    @State private var draftEditorMode = DraftEditorMode.hidden
    @State private var prefersHardwareEditor = false
    @State private var dictationBaseline = ""
    @State private var microphoneHovered = false
    @State private var voiceDockHeight: CGFloat = 0
    @State private var followsTranscriptBottom = true
    @State private var transcriptIsAtBottom = true
    @State private var showsScriptOutput = false

    init(threadID: String) {
        _model = State(initialValue: ThreadDetailModel(threadID: threadID))
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
                transcript
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
        .sheet(isPresented: $showsScriptOutput) {
            ScriptRunOutputView(model: model)
        }
        .onDisappear { model.stop() }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            threadStateBar
            Divider()

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
                            case let .activityBatch(activities):
                                ActivityBatchRow(activities: activities)
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
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 8
                } action: { _, isAtBottom in
                    transcriptIsAtBottom = isAtBottom
                    if isAtBottom {
                        followsTranscriptBottom = true
                    }
                }
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .interacting:
                        followsTranscriptBottom = false
                    case .idle where transcriptIsAtBottom:
                        followsTranscriptBottom = true
                    default:
                        break
                    }
                }
                .onChange(of: model.transcriptRevision) {
                    guard followsTranscriptBottom else { return }
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
                .task(id: voiceDockHeight) {
                    guard voiceDockHeight > 0, followsTranscriptBottom else { return }
                    await Task.yield()
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
                .task(id: model.thread?.id) {
                    await Task.yield()
                    followsTranscriptBottom = true
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !followsTranscriptBottom, !transcriptIsAtBottom {
                        Button {
                            followsTranscriptBottom = true
                            proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(.blue)
                        .padding(16)
                    }
                }
            }

            Divider()
            voiceDock
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
            if let primaryDeployScript {
                Button {
                    runDeployScript(primaryDeployScript)
                } label: {
                    if model.isScriptRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Deploying…")
                        }
                    } else {
                        Label("Deploy", systemImage: scriptSystemImage(primaryDeployScript))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityHint(
                    model.isScriptRunning
                        ? "Shows live deployment output"
                        : "Runs \(primaryDeployScript.name) in this task's worktree"
                )

                if deployScripts.count > 1 {
                    Menu {
                        ForEach(Array(deployScripts.dropFirst())) { script in
                            Button {
                                runDeployScript(script)
                            } label: {
                                Label(script.name, systemImage: scriptSystemImage(script))
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isScriptRunning)
                    .accessibilityLabel("More deploy actions")
                }
            }
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
        let sorted = (messages + activities).sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }

        var entries: [TranscriptEntry] = []
        var toolBatch: [OrchestrationActivity] = []

        func flushToolBatch() {
            guard !toolBatch.isEmpty else { return }
            if toolBatch.count == 1, let activity = toolBatch.first {
                entries.append(.activity(activity))
            } else {
                entries.append(.activityBatch(toolBatch))
            }
            toolBatch.removeAll(keepingCapacity: true)
        }

        for entry in sorted {
            if case let .activity(activity) = entry, activity.tone == "tool" {
                toolBatch.append(activity)
            } else {
                flushToolBatch()
                entries.append(entry)
            }
        }
        flushToolBatch()
        return entries
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
        activeProject?.title
    }

    private var activeProject: OrchestrationProject? {
        guard let projectID = model.thread?.projectId else { return nil }
        return appModel.snapshot?.projects.first { $0.id == projectID }
    }

    private var deployScripts: [ProjectScript] {
        (activeProject?.scripts ?? []).filter {
            !$0.runOnWorktreeCreate
                && $0.name.localizedCaseInsensitiveContains("deploy")
        }
    }

    private var primaryDeployScript: ProjectScript? {
        deployScripts.first
    }

    private func runDeployScript(_ script: ProjectScript) {
        showsScriptOutput = true
        guard !model.isScriptRunning, let activeProject else { return }
        model.runScript(script, project: activeProject, using: appModel)
    }

    private func scriptSystemImage(_ script: ProjectScript) -> String {
        switch script.icon {
        case "build": "hammer.fill"
        case "debug": "ladybug.fill"
        default: "play.fill"
        }
    }

    private var voicePreview: String {
        let committed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = model.volatileDictation.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return volatile }
        if volatile.isEmpty { return committed }
        return "\(committed) \(volatile)"
    }
}

private struct ScriptRunOutputView: View {
    let model: ThreadDetailModel

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var followsOutputBottom = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if model.scriptActionState.isRunning {
                    ProgressView()
                } else {
                    Image(systemName: model.scriptActionState.systemImage)
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.activeScriptName ?? "Deploy")
                        .font(.headline)
                    Text(model.scriptActionState.label)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
                Spacer()
                Button(model.scriptActionState.isRunning ? "Hide" : "Done") {
                    dismiss()
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(outputText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)

                    Color.clear
                        .frame(height: 1)
                        .id("script-output-bottom")
                }
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            followsOutputBottom = false
                        }
                )
                .onChange(of: model.scriptOutput.count) {
                    guard followsOutputBottom else { return }
                    proxy.scrollTo("script-output-bottom", anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsOutputBottom {
                        Button {
                            followsOutputBottom = true
                            proxy.scrollTo("script-output-bottom", anchor: .bottom)
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .padding(12)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 440)
    }

    private var outputText: String {
        model.visibleScriptOutput.isEmpty
            ? "Waiting for terminal output…"
            : model.visibleScriptOutput
    }

    private var statusColor: Color {
        switch model.scriptActionState {
        case .failed: .red
        case .succeeded: .green
        case .idle, .starting, .running: .secondary
        }
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

private struct ActivityBatchRow: View {
    let activities: [OrchestrationActivity]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                        .frame(width: 18)
                    Text(summary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(summary), \(expanded ? "collapse" : "expand") actions")

            if expanded {
                VStack(spacing: 8) {
                    ForEach(activities, id: \.id) { activity in
                        ActivityRow(activity: activity)
                    }
                }
                .padding(.leading, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        let counts = Dictionary(grouping: activities) {
            $0.payload["itemType"]?.stringValue ?? "other"
        }.mapValues(\.count)
        var parts: [String] = []

        appendCount(counts["command_execution"], singular: "Ran 1 command", plural: "Ran %d commands", to: &parts)
        appendCount(counts["file_change"], singular: "Changed 1 file", plural: "Changed %d files", to: &parts)
        appendCount(counts["mcp_tool_call"], singular: "Used 1 tool", plural: "Used %d tools", to: &parts)
        appendCount(counts["web_search"], singular: "Searched the web once", plural: "Searched the web %d times", to: &parts)
        appendCount(counts["image_generation"], singular: "Generated 1 image", plural: "Generated %d images", to: &parts)

        let recognized = [
            "command_execution",
            "file_change",
            "mcp_tool_call",
            "web_search",
            "image_generation",
        ].reduce(0) { $0 + (counts[$1] ?? 0) }
        let otherCount = activities.count - recognized
        appendCount(otherCount, singular: "1 other action", plural: "%d other actions", to: &parts)

        return parts.isEmpty ? "\(activities.count) tool actions" : parts.joined(separator: " · ")
    }

    private func appendCount(
        _ count: Int?,
        singular: String,
        plural: String,
        to parts: inout [String]
    ) {
        guard let count, count > 0 else { return }
        parts.append(count == 1 ? singular : String(format: plural, count))
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
        activity.payload["detail"]?.stringValue
            ?? activity.payload["message"]?.stringValue
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
