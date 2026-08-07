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

    var sessionStatus: String { thread?.session?.status ?? "not bound" }

    var turnState: String { thread?.latestTurn?.state ?? "none" }

    var activeTurnID: String? {
        guard let thread else { return nil }
        return thread.session?.activeTurnId
            ?? (thread.latestTurn?.state == "running" ? thread.latestTurn?.turnId : nil)
    }

    var transcriptRevision: String {
        guard let last = thread?.messages.last else { return "empty" }
        return "\(last.id):\(last.updatedAt):\(last.text.count):\(last.streaming)"
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

        actionTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            await performSend(text: text, using: appModel)
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

    private func performSend(text: String, using appModel: AppModel) async {
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
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draft = ""
            }
            actionNotice = steering ? "Redirect sent as the next turn." : "Message sent."
            scheduleRefresh(using: appModel)
        } catch is CancellationError {
            return
        } catch {
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

                        ForEach(model.thread?.messages ?? []) { message in
                            MessageBubble(message: message)
                                .id(message.id)
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
                .task(id: model.thread?.id) {
                    await Task.yield()
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
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
                        ProgressView()
                            .controlSize(.mini)
                        Text(label)
                    }
                    .font(.caption)
                } else {
                    Label(
                        model.isTurnRunning ? "Agent is working" : "Ready",
                        systemImage: model.isTurnRunning ? "circle.fill" : "circle"
                    )
                    .font(.caption)
                    .foregroundStyle(model.isTurnRunning ? Color.green : Color.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                model.interrupt(using: appModel)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
            .accessibilityHint("Always dispatches an interrupt using the latest known turn ID")
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
                    .font(.caption)
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
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(
                    model.isBusy
                        || (!model.isDictating
                            && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
            }

            Text(
                model.isDictating
                    ? "Listening · tap the microphone to stop"
                    : model.isTurnRunning
                        ? "Speaking now will stop and redirect the agent."
                        : "Tap the microphone to start"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
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
        .hoverEffectDisabled()
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
