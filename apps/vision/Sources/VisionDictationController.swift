import AVFoundation
import Foundation
import WhisperKit

enum VisionDictationError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "T3 Vision needs microphone access to dictate."
        }
    }
}

@MainActor
private final class VisionWhisperKitPipeline {
    static let shared = VisionWhisperKitPipeline()
    static let model = "large-v3-v20240930_626MB"

    private var whisperKit: WhisperKit?
    private var preparationTask: Task<WhisperKit, Error>?

    func prepare() async throws {
        _ = try await preparedWhisperKit()
    }

    func transcribe(audioURL: URL) async throws -> String {
        let whisperKit = try await preparedWhisperKit()
        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: DecodingOptions(
                language: nil,
                temperature: 0,
                detectLanguage: true,
                withoutTimestamps: true
            )
        )
        return results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func preparedWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if let preparationTask {
            return try await preparationTask.value
        }

        let preparationTask = Task { @MainActor in
            let modelFolder = try await WhisperKit.download(variant: Self.model)
            let whisperKit = try await WhisperKit(WhisperKitConfig(
                modelFolder: modelFolder.path,
                verbose: false,
                prewarm: false,
                load: false,
                download: false
            ))
            try await whisperKit.prewarmModels()
            try await whisperKit.loadModels()
            return whisperKit
        }
        self.preparationTask = preparationTask

        do {
            let whisperKit = try await preparationTask.value
            self.whisperKit = whisperKit
            self.preparationTask = nil
            return whisperKit
        } catch {
            self.preparationTask = nil
            throw error
        }
    }
}

/// Records one utterance and transcribes it locally with WhisperKit. WhisperKit
/// is batch-based, so text is committed after the user stops recording.
@MainActor
final class VisionDictationController {
    private let recorder = SpeechLabRecorder()
    private var isRunning = false

    // Kept as part of the controller contract even though batch transcription
    // does not emit volatile phrases.
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
        // WhisperKit does not consume SpeechAnalyzer contextual strings. Keep
        // the parameter so the composer API can add prompt tokens later.
        _ = contextualStrings
        try await VisionWhisperKitPipeline.shared.prepare()
        try Task.checkCancellation()
        try recorder.start()
        isRunning = true
    }

    func finish() async {
        guard isRunning else { return }
        isRunning = false
        do {
            let recording = try recorder.stop()
            defer { try? FileManager.default.removeItem(at: recording.fileURL) }
            let text = try await VisionWhisperKitPipeline.shared.transcribe(
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
    }
}
