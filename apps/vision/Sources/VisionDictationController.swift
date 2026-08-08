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

enum VisionDictationPreparationState: Equatable, Sendable {
    case notStarted
    case checkingCache(String)
    case downloading(String, Int)
    case loading(String)
    case loadingSlowly(String)
    case ready
    case failed(String, String)

    var isPreparing: Bool {
        switch self {
        case .checkingCache, .downloading, .loading, .loadingSlowly: true
        case .notStarted, .ready, .failed: false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var preparingModel: String? {
        switch self {
        case let .checkingCache(model), let .downloading(model, _),
             let .loading(model), let .loadingSlowly(model):
            model
        case .notStarted, .ready, .failed:
            nil
        }
    }
}

private final class VisionWhisperKitProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercentage = -1

    func nextPercentage(from progress: Progress) -> Int? {
        let percentage = min(100, max(0, Int(progress.fractionCompleted * 100)))
        lock.lock()
        defer { lock.unlock() }
        guard percentage > lastPercentage else { return nil }
        lastPercentage = percentage
        return percentage
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
@Observable
final class VisionWhisperKitService {
    static let shared = VisionWhisperKitService()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.t3tools.t3code.vision",
        category: "Dictation"
    )

    private(set) var state = VisionDictationPreparationState.notStarted
    @ObservationIgnored
    private var baseKit: WhisperKit?
    @ObservationIgnored
    private var largeKit: WhisperKit?
    @ObservationIgnored
    private var preparationTask: Task<Void, Never>?

    var activeEngineName: String {
        if largeKit != nil { return "WhisperKit Large v3" }
        if baseKit != nil { return "WhisperKit Base" }
        return "System dictation"
    }

    var statusLabel: String? {
        switch state {
        case .notStarted:
            "System dictation ready · Starting WhisperKit upgrades…"
        case let .checkingCache(model):
            "\(activeEngineName) ready · Checking \(model) cache…"
        case let .downloading(model, percentage):
            "\(activeEngineName) ready · Downloading \(model)… \(percentage)%"
        case let .loading(model):
            "\(activeEngineName) ready · Loading \(model)…"
        case let .loadingSlowly(model):
            "\(activeEngineName) remains available · \(model) is taking longer than expected to load."
        case .ready:
            nil
        case let .failed(model, message):
            "\(activeEngineName) remains available · \(model) could not load: \(message)"
        }
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

    func retry() async {
        guard state.isFailure else { return }
        await prepareIfNeeded()
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
            state = .ready
            return
        }
        do {
            largeKit = try await loadModel(.large)
            state = .ready
            Self.logger.notice("WhisperKit Large v3 is ready")
        } catch {
            state = .failed(
                VisionWhisperKitModelSpec.large.displayName,
                error.localizedDescription
            )
            Self.logger.error(
                "WhisperKit Large v3 failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func loadModel(_ spec: VisionWhisperKitModelSpec) async throws -> WhisperKit {
        let preparationStartedAt = Date()
        state = .checkingCache(spec.displayName)
        Self.logger.notice("[model] \(spec.displayName, privacy: .public) cache check started")

        let modelFolder: URL
        if let cachedModelFolder = Self.cachedModelFolder(spec) {
            modelFolder = cachedModelFolder
            Self.logger.notice(
                "[model] \(spec.displayName, privacy: .public) cache hit at \(cachedModelFolder.path, privacy: .private(mask: .hash))"
            )
        } else {
            Self.logger.notice("[model] \(spec.displayName, privacy: .public) cache miss; download started")
            let progressReporter = VisionWhisperKitProgressReporter()
            let downloadStartedAt = Date()
            modelFolder = try await WhisperKit.download(
                variant: spec.variant,
                progressCallback: { progress in
                    guard let percentage = progressReporter.nextPercentage(from: progress) else {
                        return
                    }
                    Task { @MainActor [weak self] in
                        guard let self, state.preparingModel == spec.displayName else { return }
                        state = .downloading(spec.displayName, percentage)
                    }
                }
            )
            Self.logger.notice(
                "[model] \(spec.displayName, privacy: .public) download finished in \(Date().timeIntervalSince(downloadStartedAt), format: .fixed(precision: 2))s"
            )
        }

        state = .loading(spec.displayName)
        let loadStartedAt = Date()
        Self.logger.notice("[model] \(spec.displayName, privacy: .public) Core ML load started")
        let slowLoadingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self,
                  state == .loading(spec.displayName) else { return }
            state = .loadingSlowly(spec.displayName)
        }
        defer { slowLoadingTask.cancel() }

        let whisperKit = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: false,
            load: false,
            download: false
        ))
        try await whisperKit.loadModels()
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
