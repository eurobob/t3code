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
    enum Tier: Int, Sendable {
        case base = 1
        case large = 2
    }

    let tier: Tier
    let engineName: String
    private let whisperKit: WhisperKit
    private let promptTokens: [Int]?

    init(
        whisperKit: WhisperKit,
        tier: Tier,
        engineName: String,
        contextualStrings: [String]
    ) {
        self.whisperKit = whisperKit
        self.tier = tier
        self.engineName = engineName

        let domainVocabulary = [
            "T3 Code", "visionOS", "WhisperKit", "Codex", "Claude",
            "OpenCode", "Tailscale",
        ]
        let vocabulary = (domainVocabulary + contextualStrings)
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

    func bestSession(contextualStrings: [String]) -> VisionWhisperKitSession? {
        if let largeKit {
            return VisionWhisperKitSession(
                whisperKit: largeKit,
                tier: .large,
                engineName: VisionWhisperKitModelSpec.large.displayName,
                contextualStrings: contextualStrings
            )
        }
        if let baseKit {
            return VisionWhisperKitSession(
                whisperKit: baseKit,
                tier: .base,
                engineName: VisionWhisperKitModelSpec.base.displayName,
                contextualStrings: contextualStrings
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
        state = .checkingCache(spec.displayName)
        Self.logger.notice("Checking the \(spec.displayName, privacy: .public) cache")

        let modelFolder: URL
        if let cachedModelFolder = Self.cachedModelFolder(spec) {
            modelFolder = cachedModelFolder
        } else {
            let progressReporter = VisionWhisperKitProgressReporter()
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
        }

        state = .loading(spec.displayName)
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

/// Starts with Apple's recognizer and additively upgrades the same buffered
/// utterance through whichever WhisperKit tier becomes available.
@MainActor
final class VisionDictationController {
    private static let liveUpdateSampleInterval = 24_000
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.t3tools.t3code.vision",
        category: "Dictation"
    )

    private let systemController = VisionSystemDictationController()
    private var isRunning = false
    private var liveTranscriptionTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<Void>.Continuation?
    private var contextualStrings: [String] = []
    private var systemFinalizedText = ""
    private var systemVolatileText = ""
    private var whisperPreviewTier: VisionWhisperKitSession.Tier?

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
        self.contextualStrings = contextualStrings
        systemFinalizedText = ""
        systemVolatileText = ""
        whisperPreviewTier = nil

        let (bufferSignals, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        systemController.onBufferCaptured = {
            continuation.yield(())
        }
        do {
            try await systemController.start(contextualStrings: contextualStrings)
        } catch {
            continuation.finish()
            systemController.onBufferCaptured = nil
            throw error
        }

        bufferContinuation = continuation
        isRunning = true
        liveTranscriptionTask = Task { [weak self] in
            await self?.transcribeLiveUpdates(from: bufferSignals)
        }
    }

    func finish() async {
        guard isRunning else { return }
        isRunning = false
        let samples = systemController.snapshotSamples()
        await systemController.finish()
        await stopLiveUpdates()

        let fallbackText = combinedSystemText
        if let session = VisionWhisperKitService.shared.bestSession(
            contextualStrings: contextualStrings
        ), !samples.isEmpty {
            do {
                let text = try await session.transcribe(audioSamples: samples)
                if !text.isEmpty {
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
        if !fallbackText.isEmpty { onFinalized?(fallbackText) }
        resetUtterance()
    }

    func cancel() async {
        isRunning = false
        await systemController.cancel()
        await stopLiveUpdates()
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
        guard whisperPreviewTier == nil else { return }
        onVolatile?(combinedSystemText)
    }

    private func handleSystemFinalized(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        systemFinalizedText = [systemFinalizedText, trimmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        systemVolatileText = ""
        guard whisperPreviewTier == nil else { return }
        onVolatile?(combinedSystemText)
    }

    private func stopLiveUpdates() async {
        systemController.onBufferCaptured = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        liveTranscriptionTask?.cancel()
        await liveTranscriptionTask?.value
        liveTranscriptionTask = nil
    }

    private func transcribeLiveUpdates(from signals: AsyncStream<Void>) async {
        var lastTranscribedSampleCount = 0
        for await _ in signals {
            guard !Task.isCancelled, isRunning else { return }
            let samples = systemController.snapshotSamples()
            guard samples.count >= Self.liveUpdateSampleInterval,
                  samples.count - lastTranscribedSampleCount
                    >= Self.liveUpdateSampleInterval,
                  let session = VisionWhisperKitService.shared.bestSession(
                    contextualStrings: contextualStrings
                  ) else { continue }
            lastTranscribedSampleCount = samples.count

            do {
                let text = try await session.transcribe(audioSamples: samples)
                guard !Task.isCancelled, isRunning else { return }
                guard !text.isEmpty else { continue }
                whisperPreviewTier = session.tier
                onVolatile?(text)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "Live \(session.engineName, privacy: .public) transcription failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func resetUtterance() {
        contextualStrings = []
        systemFinalizedText = ""
        systemVolatileText = ""
        whisperPreviewTier = nil
    }
}
