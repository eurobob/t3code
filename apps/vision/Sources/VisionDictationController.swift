import AVFoundation
import Foundation
import Observation
import OSLog
import WhisperKit

enum VisionDictationError: LocalizedError {
    case localeUnsupported
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .localeUnsupported:
            "Dictation does not support this device's language yet."
        case .microphonePermissionDenied:
            "T3 Vision needs microphone access to dictate."
        }
    }
}

private struct VisionWhisperKitModelSpec: Sendable {
    let variant: String
    let folderName: String
    let displayName: String

    static let base = VisionWhisperKitModelSpec(
        variant: "base",
        folderName: "openai_whisper-base",
        displayName: "WhisperKit Base"
    )
    static let large = VisionWhisperKitModelSpec(
        variant: "large-v3-v20240930_626MB",
        folderName: "openai_whisper-large-v3-v20240930_626MB",
        displayName: "WhisperKit Large v3"
    )
}

@MainActor
final class VisionWhisperKitSession {
    let engineName: String
    private let whisperKit: WhisperKit
    private let promptTokens: [Int]?

    init(
        whisperKit: WhisperKit,
        engineName: String
    ) {
        self.whisperKit = whisperKit
        self.engineName = engineName

        let domainVocabulary = [
            "T3 Code", "visionOS", "WhisperKit", "Codex", "Claude",
            "OpenCode", "Tailscale",
        ]
        // Project and branch names are useful to SpeechAnalyzer, but they are
        // too strong as a Whisper decoder prompt and can be hallucinated over
        // otherwise valid speech. Keep this prompt small and stable.
        let vocabulary = domainVocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let tokenizer = whisperKit.tokenizer, !vocabulary.isEmpty {
            promptTokens = tokenizer
                .encode(text: " " + vocabulary.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        } else {
            promptTokens = nil
        }
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        let results = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: DecodingOptions(
                language: nil,
                temperature: 0,
                detectLanguage: true,
                withoutTimestamps: true,
                promptTokens: promptTokens
            )
        )
        return results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@MainActor
final class VisionWhisperKitService {
    static let shared = VisionWhisperKitService()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.t3tools.t3code.vision",
        category: "Dictation"
    )

    private var baseKit: WhisperKit?
    private var largeKit: WhisperKit?
    private var preparationTask: Task<Void, Never>?

    var activeEngineName: String {
        if largeKit != nil { return "WhisperKit Large v3" }
        if baseKit != nil { return "WhisperKit Base" }
        return "System dictation"
    }

    func prepareIfNeeded() async {
        if largeKit != nil { return }
        if let preparationTask {
            await preparationTask.value
            return
        }

        let preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runPreparation()
        }
        self.preparationTask = preparationTask
        await preparationTask.value
        self.preparationTask = nil
    }

    func bestSession() -> VisionWhisperKitSession? {
        if let largeKit {
            return VisionWhisperKitSession(
                whisperKit: largeKit,
                engineName: VisionWhisperKitModelSpec.large.displayName
            )
        }
        if let baseKit {
            return VisionWhisperKitSession(
                whisperKit: baseKit,
                engineName: VisionWhisperKitModelSpec.base.displayName
            )
        }
        return nil
    }

    private func runPreparation() async {
        if baseKit == nil {
            do {
                baseKit = try await loadModel(.base)
                Self.logger.notice("WhisperKit Base is ready")
            } catch {
                Self.logger.error(
                    "WhisperKit Base failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard largeKit == nil else {
            return
        }
        do {
            largeKit = try await loadModel(.large)
            Self.logger.notice("WhisperKit Large v3 is ready")
        } catch {
            Self.logger.error(
                "WhisperKit Large v3 failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func loadModel(_ spec: VisionWhisperKitModelSpec) async throws -> WhisperKit {
        let preparationStartedAt = Date()
        Self.logger.notice("[model] \(spec.displayName, privacy: .public) cache check started")

        let modelFolder: URL
        if let cachedModelFolder = Self.cachedModelFolder(spec) {
            modelFolder = cachedModelFolder
            Self.logger.notice(
                "[model] \(spec.displayName, privacy: .public) cache hit at \(cachedModelFolder.path, privacy: .private(mask: .hash))"
            )
        } else {
            Self.logger.notice("[model] \(spec.displayName, privacy: .public) cache miss; download started")
            let downloadStartedAt = Date()
            modelFolder = try await WhisperKit.download(
                variant: spec.variant
            )
            Self.logger.notice(
                "[model] \(spec.displayName, privacy: .public) download finished in \(Date().timeIntervalSince(downloadStartedAt), format: .fixed(precision: 2))s"
            )
        }

        let loadStartedAt = Date()
        let previousLoad = UserDefaults.standard.double(
            forKey: "vision.dictation.model-load.\(spec.variant)"
        )
        if previousLoad > 0 {
            Self.logger.notice(
                "[model] \(spec.displayName, privacy: .public) previous load took \(previousLoad, format: .fixed(precision: 2))s"
            )
        }
        Self.logger.notice("[model] \(spec.displayName, privacy: .public) Core ML load started")

        let whisperKit = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        ))
        try await whisperKit.loadModels()
        let totalLoad = Date().timeIntervalSince(loadStartedAt)
        UserDefaults.standard.set(
            totalLoad,
            forKey: "vision.dictation.model-load.\(spec.variant)"
        )
        let timings = whisperKit.currentTimings
        let measuredComponents = timings.decoderLoadTime
            + timings.encoderLoadTime
            + timings.tokenizerLoadTime
        let otherLoadTime = max(0, totalLoad - measuredComponents)
        Self.logger.notice(
            "[model] \(spec.displayName, privacy: .public) components: decoder \(timings.decoderLoadTime, format: .fixed(precision: 2))s, encoder \(timings.encoderLoadTime, format: .fixed(precision: 2))s, tokenizer \(timings.tokenizerLoadTime, format: .fixed(precision: 2))s, Mel/other \(otherLoadTime, format: .fixed(precision: 2))s"
        )
        Self.logger.notice(
            "[model] \(spec.displayName, privacy: .public) Core ML load finished in \(Date().timeIntervalSince(loadStartedAt), format: .fixed(precision: 2))s; total \(Date().timeIntervalSince(preparationStartedAt), format: .fixed(precision: 2))s"
        )
        return whisperKit
    }

    private static func cachedModelFolder(_ spec: VisionWhisperKitModelSpec) -> URL? {
        let repository = HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml")
        let folder = HubApiWrapper.shared
            .localRepoLocation(repository)
            .appending(path: spec.folderName)
        let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let hasRequiredModels = requiredModels.allSatisfy { name in
            FileManager.default.fileExists(
                atPath: folder.appending(path: "\(name).mlmodelc").path
            ) || FileManager.default.fileExists(
                atPath: folder.appending(path: "\(name).mlpackage").path
            )
        }
        return hasRequiredModels ? folder : nil
    }
}

/// Owns the text and lifecycle for a draft that accepts speech. Keeping this
/// separate from any one composer gives task creation and thread steering the
/// same finalized-text, preview, and cancel behavior.
@MainActor
@Observable
final class VisionDictationDraft {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case listening
        case finishing

        var label: String? {
            switch self {
            case .idle: nil
            case let .preparing(label): label
            case .listening: "Listening…"
            case .finishing: "Transcribing on device…"
            }
        }
    }

    var text: String
    private(set) var phase = Phase.idle
    private(set) var volatileText = ""
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let controller: VisionDictationController
    @ObservationIgnored
    private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored
    private var isActive = false
    @ObservationIgnored
    private var committedText = ""
    @ObservationIgnored
    private var completionAfterFinish: ((Bool) -> Void)?

    init(text: String = "") {
        self.text = text
        let controller = VisionDictationController()
        self.controller = controller
        controller.onVolatile = { [weak self] text in
            guard self?.isActive == true else { return }
            self?.volatileText = text
        }
        controller.onFinalized = { [weak self] text in
            self?.commitFinalizedPhrase(text)
        }
        controller.onError = { [weak self] message in
            self?.finishWithError(message)
        }
    }

    var isDictating: Bool { phase != .idle }

    var previewText: String {
        let committed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return volatile }
        if volatile.isEmpty { return committed }
        return "\(committed) \(volatile)"
    }

    func presentError(_ message: String) {
        errorMessage = message
    }

    func begin(vocabulary: [String]) {
        guard !isActive else { return }

        isActive = true
        committedText = ""
        volatileText = ""
        errorMessage = nil
        phase = .preparing("Starting microphone…")
        let previousTask = lifecycleTask
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            guard !Task.isCancelled, isActive else { return }
            let granted = await VisionDictationController.requestPermission()
            guard !Task.isCancelled, isActive else { return }
            guard granted else {
                finishWithError(
                    VisionDictationError.microphonePermissionDenied.localizedDescription
                )
                return
            }
            do {
                try await controller.start(contextualStrings: vocabulary)
                guard isActive else {
                    await controller.cancel()
                    return
                }
                if case .preparing = phase { phase = .listening }
            } catch is CancellationError {
                return
            } catch {
                finishWithError(error.localizedDescription)
            }
        }
    }

    /// Stops capture, waits for the in-flight phrase to finalize, then reports
    /// whether the caller can safely submit the resulting draft.
    func finish(onFinished: ((Bool) -> Void)? = nil) {
        if completionAfterFinish == nil {
            completionAfterFinish = onFinished
        }
        guard isActive else {
            let completion = completionAfterFinish
            completionAfterFinish = nil
            completion?(errorMessage == nil)
            return
        }
        guard phase != .finishing else { return }

        phase = .finishing
        let preparationTask = lifecycleTask
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            await preparationTask?.value
            guard isActive else { return }
            await controller.finish()
            guard isActive else { return }

            isActive = false
            volatileText = ""
            committedText = ""
            phase = .idle
            lifecycleTask = nil
            let completion = completionAfterFinish
            completionAfterFinish = nil
            completion?(true)
        }
    }

    func cancel() {
        guard isActive || phase != .idle else { return }
        isActive = false
        lifecycleTask?.cancel()
        let controller = controller
        lifecycleTask = Task {
            await controller.cancel()
        }
        volatileText = ""
        phase = .idle
        let completion = completionAfterFinish
        completionAfterFinish = nil

        if !committedText.isEmpty, text.hasSuffix(committedText) {
            text.removeLast(committedText.count)
        }
        committedText = ""
        completion?(false)
    }

    private func commitFinalizedPhrase(_ phrase: String) {
        guard isActive else { return }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        let appended = separator + trimmed
        text += appended
        committedText += appended
        volatileText = ""
    }

    private func finishWithError(_ message: String) {
        let needsCleanup = phase != .finishing
        isActive = false
        phase = .idle
        volatileText = ""
        errorMessage = message
        let completion = completionAfterFinish
        completionAfterFinish = nil
        completion?(false)
        if needsCleanup {
            let controller = controller
            lifecycleTask = Task {
                await controller.cancel()
            }
        }
    }
}

/// Streams Apple's recognizer for a stable live preview, then lets the best
/// available WhisperKit tier refine the buffered utterance when it agrees.
@MainActor
final class VisionDictationController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.t3tools.t3code.vision",
        category: "Dictation"
    )

    private let systemController = VisionSystemDictationController()
    private var isRunning = false
    private var systemFinalizedText = ""
    private var systemVolatileText = ""
    private var lastSystemPreview = ""
    private var utteranceID = ""
    private var utteranceStartedAt = Date()

    var onVolatile: (@MainActor @Sendable (String) -> Void)?
    var onFinalized: (@MainActor @Sendable (String) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?

    init() {
        systemController.onVolatile = { [weak self] text in
            self?.handleSystemVolatile(text)
        }
        systemController.onFinalized = { [weak self] text in
            self?.handleSystemFinalized(text)
        }
        systemController.onError = { [weak self] message in
            self?.onError?(message)
        }
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(contextualStrings: [String]) async throws {
        guard !isRunning else { return }
        systemFinalizedText = ""
        systemVolatileText = ""
        lastSystemPreview = ""
        utteranceID = String(UUID().uuidString.prefix(8))
        utteranceStartedAt = Date()
        Self.logger.notice(
            "[utterance \(self.utteranceID, privacy: .public)] starting with System dictation; Whisper availability: \(VisionWhisperKitService.shared.activeEngineName, privacy: .public)"
        )
        do {
            try await systemController.start(contextualStrings: contextualStrings)
        } catch {
            Self.logger.error(
                "[utterance \(self.utteranceID, privacy: .public)] System dictation start failed: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        isRunning = true
        Self.logger.notice("[utterance \(self.utteranceID, privacy: .public)] microphone capture started")
    }

    func finish() async {
        guard isRunning else { return }
        isRunning = false
        await systemController.finish()
        let samples = systemController.snapshotSamples()

        let fallbackText = combinedSystemText
        Self.logger.notice(
            "[utterance \(self.utteranceID, privacy: .public)] capture stopped after \(Date().timeIntervalSince(self.utteranceStartedAt), format: .fixed(precision: 2))s with \(samples.count, privacy: .public) samples and \(fallbackText.count, privacy: .public) System characters"
        )
        if let session = VisionWhisperKitService.shared.bestSession(), !samples.isEmpty {
            do {
                let transcriptionStartedAt = Date()
                Self.logger.notice(
                    "[utterance \(self.utteranceID, privacy: .public)] final \(session.engineName, privacy: .public) pass started"
                )
                let text = try await session.transcribe(audioSamples: samples)
                let decision = Self.whisperDecision(
                    candidate: text,
                    fallback: fallbackText
                )
                Self.logger.notice(
                    "[utterance \(self.utteranceID, privacy: .public)] final \(session.engineName, privacy: .public) pass finished in \(Date().timeIntervalSince(transcriptionStartedAt), format: .fixed(precision: 2))s with \(text.count, privacy: .public) characters; \(decision.reason, privacy: .public)"
                )
                if decision.accepted {
                    onFinalized?(text)
                    resetUtterance()
                    return
                }
            } catch {
                Self.logger.error(
                    "Final \(session.engineName, privacy: .public) transcription failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if !fallbackText.isEmpty {
            Self.logger.notice("[utterance \(self.utteranceID, privacy: .public)] selected System dictation fallback")
            onFinalized?(fallbackText)
        } else {
            Self.logger.error("[utterance \(self.utteranceID, privacy: .public)] no engine produced text")
        }
        resetUtterance()
    }

    func cancel() async {
        isRunning = false
        await systemController.cancel()
        Self.logger.notice("[utterance \(self.utteranceID, privacy: .public)] cancelled")
        resetUtterance()
    }

    private var combinedSystemText: String {
        [systemFinalizedText, systemVolatileText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func handleSystemVolatile(_ text: String) {
        systemVolatileText = text
        let preview = combinedSystemText
        guard !preview.isEmpty else { return }
        if !lastSystemPreview.isEmpty,
           preview.count + 8 < lastSystemPreview.count,
           Double(preview.count) < Double(lastSystemPreview.count) * 0.6 {
            Self.logger.notice(
                "[utterance \(self.utteranceID, privacy: .public)] ignored System volatile regression from \(self.lastSystemPreview.count, privacy: .public) to \(preview.count, privacy: .public) characters"
            )
            return
        }
        lastSystemPreview = preview
        onVolatile?(preview)
    }

    private func handleSystemFinalized(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        systemFinalizedText = [systemFinalizedText, trimmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        systemVolatileText = ""
        let preview = combinedSystemText
        lastSystemPreview = preview
        onVolatile?(preview)
    }

    private func resetUtterance() {
        systemFinalizedText = ""
        systemVolatileText = ""
        lastSystemPreview = ""
        utteranceID = ""
    }

    private static func whisperDecision(
        candidate: String,
        fallback: String
    ) -> (accepted: Bool, reason: String) {
        let candidateWords = normalizedWords(candidate)
        guard !candidateWords.isEmpty else { return (false, "rejected empty output") }

        let counts = Dictionary(grouping: candidateWords, by: { $0 }).mapValues(\.count)
        if let mostRepeated = counts.values.max(),
           mostRepeated >= 4,
           Double(mostRepeated) / Double(candidateWords.count) > 0.45 {
            return (false, "rejected repetitive output")
        }

        let fallbackWords = normalizedWords(fallback)
        guard !fallbackWords.isEmpty else {
            return (false, "rejected because System dictation heard no speech")
        }

        let lengthRatio = Double(candidate.count) / Double(max(1, fallback.count))
        guard (0.45...2.2).contains(lengthRatio) else {
            return (false, "rejected implausible length ratio")
        }

        let candidateSet = Set(candidateWords)
        let fallbackSet = Set(fallbackWords)
        let shared = candidateSet.intersection(fallbackSet).count
        let overlap = Double(shared) / Double(max(1, min(candidateSet.count, fallbackSet.count)))
        let compactCandidate = candidateWords.joined()
        let compactFallback = fallbackWords.joined()
        guard overlap >= 0.35 || compactCandidate == compactFallback else {
            return (false, "rejected low agreement with System dictation")
        }
        return (true, "accepted with \(Int(overlap * 100))% token agreement")
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

}
