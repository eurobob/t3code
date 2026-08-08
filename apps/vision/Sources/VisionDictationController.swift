import AVFoundation
import Foundation
import Observation
import OSLog
import WhisperKit

enum VisionDictationError: LocalizedError {
    case microphonePermissionDenied
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "T3 Vision needs microphone access to dictate."
        case .modelUnavailable:
            "WhisperKit is not ready yet."
        }
    }
}

enum VisionDictationPreparationState: Equatable, Sendable {
    case notStarted
    case checkingCache
    case downloading(Int)
    case loading
    case loadingSlowly
    case ready
    case failed(String)

    var label: String? {
        switch self {
        case .notStarted:
            "WhisperKit has not started loading."
        case .checkingCache:
            "Checking WhisperKit model cache…"
        case let .downloading(percentage):
            "Downloading WhisperKit model… \(percentage)%"
        case .loading:
            "Loading WhisperKit…"
        case .loadingSlowly:
            "WhisperKit is taking longer than expected to load. Dictation will become available when it is ready."
        case .ready:
            nil
        case let .failed(message):
            "WhisperKit is unavailable: \(message)"
        }
    }

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

@MainActor
@Observable
final class VisionWhisperKitService {
    static let shared = VisionWhisperKitService()
    static let model = "large-v3-v20240930_626MB"
    private static var cachedModelFolderName: String { "openai_whisper-\(model)" }
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.t3tools.t3code.vision",
        category: "Dictation"
    )

    private(set) var state = VisionDictationPreparationState.notStarted
    @ObservationIgnored
    private var whisperKit: WhisperKit?
    @ObservationIgnored
    private var preparationTask: Task<Void, Never>?

    var isReady: Bool { state == .ready && whisperKit != nil }

    func prepareIfNeeded() async {
        if isReady { return }
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

    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit, state == .ready else {
            throw VisionDictationError.modelUnavailable
        }
        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: Self.decodingOptions
        )
        return Self.joinedText(from: results)
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let whisperKit, state == .ready else {
            throw VisionDictationError.modelUnavailable
        }
        let results = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: Self.decodingOptions
        )
        return Self.joinedText(from: results)
    }

    private static let decodingOptions = DecodingOptions(
        language: nil,
        temperature: 0,
        detectLanguage: true,
        withoutTimestamps: true
    )

    private static func joinedText(from results: [TranscriptionResult]) -> String {
        return results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func runPreparation() async {
        state = .checkingCache
        Self.logger.notice("Checking the local WhisperKit model cache")
        do {
            let modelFolder: URL
            if let cachedModelFolder = Self.cachedModelFolder() {
                modelFolder = cachedModelFolder
                Self.logger.notice("Using the cached WhisperKit model")
            } else {
                let progressReporter = VisionWhisperKitProgressReporter()
                modelFolder = try await WhisperKit.download(
                    variant: Self.model,
                    progressCallback: { progress in
                        guard let percentage = progressReporter.nextPercentage(from: progress) else {
                            return
                        }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            switch state {
                            case .checkingCache, .downloading:
                                state = .downloading(percentage)
                            case .notStarted, .loading, .loadingSlowly, .ready, .failed:
                                return
                            }
                            Self.logger.notice("Downloading the WhisperKit model: \(percentage)%")
                        }
                    }
                )
            }

            state = .loading
            Self.logger.notice("Loading the WhisperKit model")
            let slowLoadingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self?.state == .loading else { return }
                self?.state = .loadingSlowly
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
            self.whisperKit = whisperKit
            state = .ready
            Self.logger.notice("WhisperKit is ready for dictation")
        } catch {
            state = .failed(error.localizedDescription)
            Self.logger.error(
                "WhisperKit preparation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func cachedModelFolder() -> URL? {
        let repository = HubApiWrapper.Repo(id: "argmaxinc/whisperkit-coreml")
        let folder = HubApiWrapper.shared
            .localRepoLocation(repository)
            .appending(path: cachedModelFolderName)
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

/// Records one utterance and transcribes it locally with WhisperKit. Partial
/// passes update the HUD; one final full-buffer pass commits text on stop.
@MainActor
final class VisionDictationController {
    private static let liveUpdateSampleInterval = 24_000
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.t3tools.t3code.vision",
        category: "Dictation"
    )

    private let recorder = SpeechLabRecorder()
    private var isRunning = false
    private var liveTranscriptionTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<Void>.Continuation?

    // Partial text is presentation-only; the full-buffer pass is finalized.
    var onVolatile: (@MainActor @Sendable (String) -> Void)?
    var onFinalized: (@MainActor @Sendable (String) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start(contextualStrings: [String]) async throws {
        guard !isRunning else { return }
        guard VisionWhisperKitService.shared.isReady else {
            throw VisionDictationError.modelUnavailable
        }
        // WhisperKit does not consume SpeechAnalyzer contextual strings. Keep
        // the parameter so the composer API can add prompt tokens later.
        _ = contextualStrings
        try Task.checkCancellation()

        let (bufferSignals, continuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        do {
            try recorder.start {
                continuation.yield(())
            }
        } catch {
            continuation.finish()
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
        let recording: SpeechLabRecording
        do {
            recording = try recorder.stop()
        } catch {
            await stopLiveUpdates()
            onError?(error.localizedDescription)
            return
        }

        await stopLiveUpdates()
        defer { try? FileManager.default.removeItem(at: recording.fileURL) }
        do {
            let text = try await VisionWhisperKitService.shared.transcribe(
                audioURL: recording.fileURL
            )
            if !text.isEmpty { onFinalized?(text) }
        } catch is CancellationError {
            return
        } catch {
            onError?(error.localizedDescription)
        }
    }

    func cancel() async {
        if isRunning { recorder.cancel() }
        isRunning = false
        await stopLiveUpdates()
    }

    private func stopLiveUpdates() async {
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
            let samples = recorder.snapshotSamples()
            guard samples.count >= Self.liveUpdateSampleInterval,
                  samples.count - lastTranscribedSampleCount
                    >= Self.liveUpdateSampleInterval else { continue }
            lastTranscribedSampleCount = samples.count

            do {
                let text = try await VisionWhisperKitService.shared.transcribe(
                    audioSamples: samples
                )
                guard !Task.isCancelled, isRunning else { return }
                onVolatile?(text)
            } catch is CancellationError {
                return
            } catch {
                // A partial pass should not discard the recording. The final
                // pass after stop can still succeed and report a useful error.
                Self.logger.error(
                    "Live transcription update failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
