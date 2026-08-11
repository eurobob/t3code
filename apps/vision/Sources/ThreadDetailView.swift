import Foundation
import Observation
import SwiftUI
import UIKit

struct VisionTaskBrief: Codable, Equatable {
    let ticket: String
    let latest: String
    let done: [String]
    let needsYou: [String]
    let modelSelection: ModelSelection
    let generatedAt: String
}

@MainActor
@Observable
final class ThreadDetailModel {
    private struct CachedTaskSummary: Codable {
        let sourceRevision: String
        let summary: VisionTaskBrief
    }

    private struct ClaudeSummaryEnvelope: Decodable {
        struct Payload: Codable {
            let ticket: String
            let latest: String
            let done: [String]
            let needsYou: [String]
        }

        let structuredOutput: Payload?
        let result: String?

        private enum CodingKeys: String, CodingKey {
            case structuredOutput = "structured_output"
            case result
        }
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

    private enum SummaryFallbackError: LocalizedError {
        case threadUnavailable
        case terminalStreamEnded
        case terminalClosed
        case commandFailed(String)
        case malformedResponse
        case lowQualityResponse

        var errorDescription: String? {
            switch self {
            case .threadUnavailable:
                "The task workspace is unavailable."
            case .terminalStreamEnded:
                "The summary process stopped before returning a result."
            case .terminalClosed:
                "The summary terminal closed before returning a result."
            case let .commandFailed(detail):
                "Claude Sonnet could not generate the task summary. \(detail)"
            case .malformedResponse:
                "Claude Sonnet returned an unreadable task summary."
            case .lowQualityResponse:
                "Claude Sonnet did not return a useful task summary. Try regenerating it."
            }
        }
    }

    private enum SummaryCommandResult {
        case success(String)
        case failure(String)
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
    private(set) var scriptActionState: ScriptActionState = .idle
    private(set) var scriptOutput = ""
    private(set) var scriptOutputWasTruncated = false
    private(set) var submissionRevision = 0
    private(set) var draftRestorationRevision = 0
    private(set) var awaitingAgentStart = false
    private(set) var optimisticMessageText: String?
    private(set) var isFinalizingDictationSubmission = false
    private(set) var generatedSummary: VisionTaskBrief?
    private(set) var generatedSummaryRevision: String?
    private(set) var summaryIsLoading = false
    private(set) var summaryError: String?
    let dictation = VisionDictationDraft()

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
    private var turnBeforeSubmissionID: String?
    @ObservationIgnored
    private var messageIDsBeforeSubmission: Set<String> = []

    init(threadID: String) {
        self.threadID = threadID
    }

    var thread: OrchestrationThread? { detail?.thread }

    var isBusy: Bool { actionState != .idle || isFinalizingDictationSubmission }

    var draft: String {
        get { dictation.text }
        set { dictation.text = newValue }
    }

    var dictationPhase: VisionDictationDraft.Phase { dictation.phase }

    var volatileDictation: String { dictation.volatileText }

    var dictationError: String? { dictation.errorMessage }

    var isDictating: Bool { dictation.isDictating }

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

    var submissionStatusLabel: String? {
        if isFinalizingDictationSubmission {
            return dictationPhase.label ?? "Transcribing on device…"
        }
        return actionState.label
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

    var summaryGenerationTaskID: String {
        if isAgentWorking {
            return "working:\(activeTurnID ?? thread?.latestTurn?.turnId ?? "pending")"
        }
        return "settled:\(summarySourceRevision ?? "none")"
    }

    var visibleGeneratedSummary: VisionTaskBrief? {
        if isAgentWorking || summaryIsLoading {
            return generatedSummary
        }
        guard generatedSummaryRevision == summarySourceRevision else { return nil }
        return generatedSummary
    }

    func start(using appModel: AppModel) async {
        guard eventsTask == nil else { return }
        if let cached = appModel.cachedThreadSnapshot(id: threadID) {
            apply(cached)
            loadState = .loaded
            startEvents(after: cached.snapshotSequence, using: appModel)
            return
        }

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
        scriptTask?.cancel()
        scriptTask = nil
        dictation.cancel()
    }

    func ensureTaskSummary(using appModel: AppModel, force: Bool = false) async {
        guard !summaryIsLoading,
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
            let summary = try await generateTaskSummaryWithClaude(using: appModel)
            try Task.checkCancellation()
            guard isAgentWorking || summarySourceRevision == sourceRevision else { return }
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

    /// Uses the environment's Claude subscription without adding a visible
    /// turn or mutating the task conversation. Keeping this client-owned avoids
    /// changing behavior with the T3 server version or configured utility model.
    private func generateTaskSummaryWithClaude(
        using appModel: AppModel
    ) async throws -> VisionTaskBrief {
        guard let thread,
              let project = appModel.snapshot?.projects.first(where: {
                  $0.id == thread.projectId
              }) else { throw SummaryFallbackError.threadUnavailable }

        let schema = #"{"type":"object","properties":{"ticket":{"type":"string","maxLength":160},"latest":{"type":"string","maxLength":160},"done":{"type":"array","items":{"type":"string","maxLength":120},"minItems":1,"maxItems":3},"needsYou":{"type":"array","items":{"type":"string","maxLength":120},"maxItems":3}},"required":["ticket","latest","done","needsYou"],"additionalProperties":false}"#
        var rejectedDraft: ClaudeSummaryEnvelope.Payload?

        for _ in 0..<2 {
            let prompt = taskSummaryPrompt(
                for: thread,
                projectTitle: project.title,
                rejectedDraft: rejectedDraft
            )
            let encodedPrompt = Data(prompt.utf8).base64EncodedString()
            let terminalID = "vision-summary-\(UUID().uuidString.lowercased())"
            let marker = "__T3_VISION_SUMMARY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
            let command = """
            stty -echo; t3_summary_prompt="$(printf %s '\(encodedPrompt)' | base64 -d 2>/dev/null)" || t3_summary_prompt="$(printf %s '\(encodedPrompt)' | base64 -D)"; t3_summary_output="$(printf %s "$t3_summary_prompt" | claude -p --model sonnet --tools '' --no-session-persistence --permission-mode dontAsk --output-format json --json-schema '\(schema)' 2>&1)"; t3_summary_status=$?; printf '\n\(marker)BEGIN\n%s\n\(marker)END:%s\n' "$t3_summary_output" "$t3_summary_status"; stty echo
            """

            let rawResponse = try await runSummaryCommand(
                command,
                marker: marker,
                terminalID: terminalID,
                thread: thread,
                project: project,
                using: appModel
            )
            let payload = try decodeClaudeSummary(rawResponse)
            if let summary = validatedTaskSummary(payload) {
                return summary
            }
            rejectedDraft = payload
        }

        throw SummaryFallbackError.lowQualityResponse
    }

    private func decodeClaudeSummary(_ rawResponse: String) throws -> ClaudeSummaryEnvelope.Payload {
        let envelope = try JSONDecoder.t3.decode(
            ClaudeSummaryEnvelope.self,
            from: Data(rawResponse.utf8)
        )
        if let structuredOutput = envelope.structuredOutput {
            return structuredOutput
        }
        if let result = envelope.result,
           let data = result.data(using: .utf8),
           let decoded = try? JSONDecoder.t3.decode(
               ClaudeSummaryEnvelope.Payload.self,
               from: data
           ) {
            return decoded
        }
        throw SummaryFallbackError.malformedResponse
    }

    private func validatedTaskSummary(
        _ payload: ClaudeSummaryEnvelope.Payload
    ) -> VisionTaskBrief? {
        let ticket = normalizedSummaryItem(payload.ticket)
        let latest = normalizedSummaryItem(payload.latest)
        let done = normalizedSummaryItems(payload.done, limit: 3)
        let needsYou = normalizedSummaryItems(payload.needsYou, limit: 3)
        let normalizedTicket = normalizedSummaryField(ticket)
        let normalizedLatest = normalizedSummaryField(latest)
        let normalizedDone = done.map(normalizedSummaryField)
        let normalizedNeedsYou = needsYou.map(normalizedSummaryField)
        let allCategorizedItems = [normalizedTicket, normalizedLatest]
            + normalizedDone + normalizedNeedsYou
        let placeholders: Set<String> = ["test", "testing", "none", "unknown", "n a", "na", "todo", "tbd"]
        let processNarration = [
            "agent is working on this now",
            "agent is currently working",
            "currently working on this",
        ]

        guard !ticket.isEmpty,
              !latest.isEmpty,
              !done.isEmpty,
              ticket.count <= 160,
              latest.count <= 160,
              done.allSatisfy({ $0.count <= 120 }),
              needsYou.allSatisfy({ $0.count <= 120 }),
              allCategorizedItems.allSatisfy({ !placeholders.contains($0) }),
              Set(allCategorizedItems).count == allCategorizedItems.count,
              !processNarration.contains(where: { phrase in
                  normalizedDone.contains(where: { $0.contains(phrase) })
              }) else { return nil }

        return VisionTaskBrief(
            ticket: ticket,
            latest: latest,
            done: done,
            needsYou: needsYou,
            modelSelection: ModelSelection(instanceId: "claude", model: "sonnet"),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func normalizedSummaryItems(_ items: [String], limit: Int) -> [String] {
        items.prefix(limit).map(normalizedSummaryItem).filter { !$0.isEmpty }
    }

    private func normalizedSummaryItem(_ item: String) -> String {
        item
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[•\-*]\s*"#, with: "", options: .regularExpression)
    }

    private func normalizedSummaryField(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func runSummaryCommand(
        _ command: String,
        marker: String,
        terminalID: String,
        thread: OrchestrationThread,
        project: OrchestrationProject,
        using appModel: AppModel
    ) async throws -> String {
        var terminalOpened = false
        defer {
            if terminalOpened {
                Task {
                    try? await appModel.closeTerminal(
                        threadID: thread.id,
                        terminalID: terminalID
                    )
                }
            }
        }

        let initial = try await appModel.openTerminal(
            threadID: thread.id,
            terminalID: terminalID,
            cwd: thread.worktreePath ?? project.workspaceRoot,
            worktreePath: thread.worktreePath,
            environmentVariables: [:]
        )
        terminalOpened = true
        if initial.status == .error || initial.status == .exited {
            throw SummaryFallbackError.commandFailed("The terminal could not start.")
        }

        let stream = try await appModel.attachTerminal(
            threadID: thread.id,
            terminalID: terminalID
        )
        var iterator = stream.makeAsyncIterator()
        try await appModel.writeTerminal(
            threadID: thread.id,
            terminalID: terminalID,
            data: "\(command)\r"
        )

        var output = initial.history
        while let event = try await iterator.next() {
            if let eventThreadID = event.threadId,
               let eventTerminalID = event.terminalId,
               (eventThreadID != thread.id || eventTerminalID != terminalID) {
                continue
            }
            switch event.type {
            case "snapshot", "started", "restarted":
                if let snapshot = event.snapshot { output = snapshot.history }
            case "output":
                if let data = event.data {
                    output.append(contentsOf: data)
                    if output.count > 200_000 {
                        output = String(output.suffix(160_000))
                    }
                }
            case "error":
                throw SummaryFallbackError.commandFailed(
                    event.message ?? "The terminal reported an error."
                )
            case "closed", "exited":
                throw SummaryFallbackError.terminalClosed
            default:
                break
            }

            if let result = extractSummaryResponse(from: output, marker: marker) {
                switch result {
                case let .success(response): return response
                case let .failure(detail): throw SummaryFallbackError.commandFailed(detail)
                }
            }
        }
        throw SummaryFallbackError.terminalStreamEnded
    }

    private func extractSummaryResponse(
        from output: String,
        marker: String
    ) -> SummaryCommandResult? {
        let normalized = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let begin = normalized.range(
            of: "\(marker)BEGIN\n",
            options: .backwards
        ), let end = normalized.range(
                  of: "\n\(marker)END:",
                  range: begin.upperBound..<normalized.endIndex
              ) else { return nil }
        let statusStart = end.upperBound
        let status = normalized[statusStart...].prefix { $0.isNumber }
        guard let exitCode = Int(status) else { return nil }
        let response = String(normalized[begin.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode == 0 { return .success(response) }
        return .failure(response.isEmpty ? "The command exited with status \(exitCode)." : response)
    }

    private func taskSummaryPrompt(
        for thread: OrchestrationThread,
        projectTitle: String,
        rejectedDraft: ClaudeSummaryEnvelope.Payload?
    ) -> String {
        var sections = [
            "Project: \(projectTitle)",
            "Task: \(thread.title)",
            "Write a return-to-ticket brief for someone who has not seen this task in a week. "
                + "Optimize for understanding in seconds, not completeness. Plain language; no "
                + "paragraphs, headings, or implementation diary. 'ticket': one line, at most 160 "
                + "characters, explaining what this ticket is trying to achieve. 'latest': one "
                + "line, at most 160 characters, stating the most recent meaningful result, finding, "
                + "blocker, or correction—never generic 'working on it' status. 'done': at most 3 "
                + "short lines naming concrete outcomes already completed or verified. 'needsYou': "
                + "at most 3 decisions or actions the user must take now; combine decisions and "
                + "actions here and return an empty array when none are required. Never ask the "
                + "user to confirm a choice they already stated. Treat the latest user correction "
                + "as authoritative. If the user rejects or criticizes an earlier result, do not "
                + "list that result as done. Commit titles and agent completion claims are not "
                + "verification. Do not "
                + "repeat facts across fields, include file inventories, or invent results.",
        ]
        if let rejectedDraft {
            sections.append(
                "A previous draft was rejected as placeholder or duplicated content. Replace it "
                    + "with terse, distinct content. Rejected ticket: \(rejectedDraft.ticket)\n"
                    + "Rejected latest: \(rejectedDraft.latest)\nRejected done: "
                    + rejectedDraft.done.joined(separator: " | ")
            )
        }
        let messages = thread.messages.suffix(40).map {
            "\($0.role.uppercased()): \(String($0.text.prefix(2_000)))"
        }
        if !messages.isEmpty {
            sections.append("Conversation:\n\(messages.joined(separator: "\n\n"))")
        }
        let activities = thread.activities.suffix(20).map {
            "\($0.kind): \($0.summary)"
        }
        if !activities.isEmpty {
            sections.append("Recent activity:\n\(activities.joined(separator: "\n"))")
        }
        if let checkpoint = thread.checkpoints.last {
            let files = checkpoint.files.prefix(30).map { "\($0.kind) \($0.path)" }
            sections.append("Latest checkpoint:\n\(files.joined(separator: "\n"))")
        }
        return sections.joined(separator: "\n\n")
    }

    private func taskSummaryCacheKey(environmentID: String?) -> String {
        "codes.t3.vision.task-summary.v5.\(environmentID ?? "unknown").\(threadID)"
    }

    func submit(using appModel: AppModel) {
        guard actionTask == nil else {
            actionError = "Another thread action is already in progress."
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            discardOptimisticSubmission()
            actionError = "Type a message before sending."
            return
        }

        let optimisticDraft = draft
        if isFinalizingDictationSubmission {
            isFinalizingDictationSubmission = false
        }
        stageOptimisticSubmission(text: text)
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

    func deploy(
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

        scriptActionState = .starting
        scriptOutput = ""
        scriptOutputWasTruncated = false
        let marker = "__T3_VISION_SCRIPT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__:"
        scriptCompletionMarker = marker

        scriptTask = Task { [weak self, weak appModel] in
            guard let self, let appModel else { return }
            await performScript(
                Self.deployCommand,
                project: project,
                thread: thread,
                completionMarker: marker,
                using: appModel
            )
            scriptTask = nil
        }
    }

    /// The bridge snapshots and pushes this task's worktree before deploying it.
    /// This is owned by T3, never by repository configuration.
    private static let deployCommand =
        "MESA_ALLOW_DEPLOY=1 mac-verify --checkpoint --deploy --logs"

    func beginDictation(vocabulary: [String]) {
        guard !isBusy else {
            dictation.presentError("Wait for the current thread action to finish.")
            return
        }
        dictation.begin(vocabulary: vocabulary)
    }

    func finishDictation() {
        dictation.finish()
    }

    func finishDictationAndSubmit(using appModel: AppModel) {
        guard !isBusy else {
            dictation.presentError("Wait for the current thread action to finish.")
            return
        }

        actionError = nil
        actionNotice = nil
        isFinalizingDictationSubmission = true
        stageOptimisticSubmission(
            text: dictation.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        submissionRevision &+= 1
        dictation.finish { [weak self, weak appModel] finished in
            guard let self else { return }
            guard finished, let appModel else {
                self.discardOptimisticSubmission()
                return
            }
            submit(using: appModel)
        }
    }

    func cancelDictation() {
        dictation.cancel()
    }

    private func performScript(
        _ command: String,
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
                data: "\(command)\r\(completionCommand)\r"
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
                        appModel.storeThreadSnapshot(snapshot)
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
        if !isFinalizingDictationSubmission,
           let optimisticMessageText,
           snapshot.thread.messages.contains(where: {
               $0.role == "user"
                   && !messageIDsBeforeSubmission.contains($0.id)
                   && $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                       == optimisticMessageText
           }) {
            clearOptimisticMessage()
        }
        if awaitingAgentStart,
           snapshot.thread.latestTurn?.turnId != turnBeforeSubmissionID {
            awaitingAgentStart = false
            turnBeforeSubmissionID = nil
        }
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
            clearOptimisticMessage()
            if draft.isEmpty {
                draft = optimisticDraft
                draftRestorationRevision &+= 1
            }
            actionError = error.localizedDescription
        }
    }

    private func stageOptimisticSubmission(text: String) {
        optimisticMessageText = text
        messageIDsBeforeSubmission = Set(thread?.messages.map(\.id) ?? [])
    }

    private func discardOptimisticSubmission() {
        isFinalizingDictationSubmission = false
        clearOptimisticMessage()
    }

    private func clearOptimisticMessage() {
        optimisticMessageText = nil
        messageIDsBeforeSubmission.removeAll(keepingCapacity: true)
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
                appModel.storeThreadSnapshot(replacement)
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
    @AppStorage("vision.tasks.showsSummaryPanel") private var showsSummaryPanel = false
    @State private var model: ThreadDetailModel
    @State private var draftEditorMode = DraftEditorMode.hidden
    @State private var prefersHardwareEditor = false
    @State private var dictationBaseline = ""
    @State private var microphoneHovered = false
    @State private var voiceDockHeight: CGFloat = 0
    @State private var followsTranscriptBottom = true
    @State private var transcriptIsAtBottom = true
    @State private var showsDeployError = false

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
        .onDisappear { model.stop() }
    }

    private var taskDetail: some View {
        VStack(spacing: 0) {
            threadStateBar
            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    chatTranscript
                    Divider()
                    voiceDock
                }
                .frame(minWidth: 520, idealWidth: 720, maxWidth: .infinity)

                if showsSummaryPanel {
                    Divider()
                    VStack(spacing: 0) {
                        summaryPanelHeader
                        Divider()
                        taskSummary
                    }
                    .frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
                }
            }
        }
        .background {
            VisionWindowWidthController(
                isExpanded: showsSummaryPanel,
                expandedWidth: 1_480,
                collapsedWidth: 900
            )
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: showsSummaryPanel ? 1_180 : 520)
    }

    private var summaryPanelHeader: some View {
        HStack(spacing: 10) {
            Label("Task summary", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Button {
                showsSummaryPanel = false
            } label: {
                Label("Close summary", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Closes the summary panel and keeps the conversation open")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                        case let .activityBatch(activities):
                            ActivityBatchRow(activities: activities)
                        }
                    }

                    if let optimisticMessageText = model.optimisticMessageText {
                        OptimisticMessageBubble(text: optimisticMessageText)
                            .id("\(model.threadID)-optimistic-message")
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
                                showsSummaryPanel = false
                            }
                        }

                        ForEach(Array(generatedActions.enumerated()), id: \.offset) { _, action in
                            TaskSummaryActionCard(action: action)
                        }
                    }
                } else {
                    Label("Nothing needs you", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TaskAtAGlanceCard(
                    ticket: model.visibleGeneratedSummary?.ticket ?? fallbackTicketSummary,
                    latest: model.visibleGeneratedSummary?.latest ?? fallbackLatestSummary,
                    isLoading: model.summaryIsLoading
                )

                TaskBriefCard(
                    title: "What was done",
                    icon: "checkmark.circle",
                    items: model.visibleGeneratedSummary?.done ?? latestResult.map { [$0] },
                    emptyText: model.summaryIsLoading
                        ? "Reading the task history…"
                        : "No completed outcome has been recorded yet.",
                    isWorking: model.isAgentWorking,
                    files: []
                )
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .task(id: model.summaryGenerationTaskID) {
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
                    Text("Summarizing with Claude Sonnet")
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
            .disabled(model.summaryIsLoading)
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
                if let label = model.submissionStatusLabel {
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
            Button {
                showsSummaryPanel.toggle()
            } label: {
                Label(
                    showsSummaryPanel ? "Hide Summary" : "Show Summary",
                    systemImage: "sparkles"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityHint(
                showsSummaryPanel
                    ? "Closes the global task summary panel"
                    : "Opens the global task summary panel beside the conversation"
            )
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
            if case .failed = model.scriptActionState {
                Button {
                    showsDeployError.toggle()
                } label: {
                    Label("Deployment failed", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .popover(isPresented: $showsDeployError, arrowEdge: .top) {
                    DeployErrorView(model: model)
                }
                .accessibilityHint("Shows the deployment error and terminal output")
            }
            if activeProject != nil {
                Button {
                    runDeploy()
                } label: {
                    if model.isScriptRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Deploying…")
                        }
                    } else {
                        Label("Deploy", systemImage: "hammer.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(model.isScriptRunning || model.isTurnRunning)
                .accessibilityHint(deployAccessibilityHint)
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
                        if model.optimisticMessageText == nil,
                           !model.volatileDictation.isEmpty {
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

            if model.isDictating,
               model.optimisticMessageText == nil,
               !voicePreview.isEmpty {
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

    private var fallbackTicketSummary: String? {
        let requests = model.thread?.messages.filter {
            $0.role == "user"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? []
        guard let original = requests.first else { return nil }
        return conciseText(original.text, limit: 180)
    }

    private var fallbackLatestSummary: String? {
        if let latestResult {
            return conciseText(latestResult, limit: 180)
        }
        return model.isAgentWorking ? "A new update is in progress." : nil
    }

    private var latestResult: String? {
        model.thread?.messages.last(where: {
            $0.role == "assistant"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }).map { conciseText($0.text) }
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
        activeProject?.title
    }

    private var activeProject: OrchestrationProject? {
        guard let projectID = model.thread?.projectId else { return nil }
        return appModel.snapshot?.projects.first { $0.id == projectID }
    }

    private func runDeploy() {
        guard !model.isScriptRunning, let activeProject else { return }
        showsDeployError = false
        model.deploy(project: activeProject, using: appModel)
    }

    private var deployAccessibilityHint: String {
        if model.isScriptRunning {
            return "The active task worktree is being deployed"
        }
        if model.isTurnRunning {
            return "Wait for the agent to finish changing this task's worktree"
        }
        return "Commits, pushes, and deploys this task's worktree"
    }

    private var voicePreview: String {
        let committed = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = model.volatileDictation.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return volatile }
        if volatile.isEmpty { return committed }
        return "\(committed) \(volatile)"
    }
}

private struct DeployErrorView: View {
    let model: ThreadDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Deployment failed")
                        .font(.headline)
                    Text(model.scriptActionState.label)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            ScrollView {
                Text(outputText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }

    private var outputText: String {
        model.visibleScriptOutput.isEmpty
            ? "Waiting for terminal output…"
            : model.visibleScriptOutput
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

private struct TaskAtAGlanceCard: View {
    let ticket: String?
    let latest: String?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("At a glance", systemImage: "scope")
                .font(.headline)

            glanceRow(label: "Ticket", text: ticket ?? ticketPlaceholder)
            Divider()
            glanceRow(label: "Latest", text: latest ?? latestPlaceholder)
        }
        .padding(16)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private func glanceRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var ticketPlaceholder: String {
        isLoading ? "Summarizing the ticket…" : "No ticket request is available."
    }

    private var latestPlaceholder: String {
        isLoading ? "Finding the latest meaningful update…" : "No update has been recorded yet."
    }
}

private struct TaskBriefCard: View {
    let title: String
    let icon: String
    let items: [String]?
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

            if let items, !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(item)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }

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
                MarkdownMessageView(
                    message.text,
                    isStreaming: message.streaming
                )
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

private struct OptimisticMessageBubble: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("User")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Preparing message")
            }

            if text.isEmpty {
                Text("Transcribing…")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                MarkdownMessageView(text, isStreaming: false)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
