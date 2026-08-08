import AVFoundation
import Foundation
import Speech

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

/// SpeechAnalyzer-backed capture for visionOS 26. Finalized phrases are
/// committed by the feature model; volatile phrases are presentation-only.
final class VisionDictationController {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var isRunning = false

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
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale.current
        ) else {
            throw VisionDictationError.localeUnsupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(context)
        }

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        )
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = continuation

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        self?.onFinalized?(text)
                    } else {
                        self?.onVolatile?(text)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.onError?(error.localizedDescription)
            }
        }

        try configureAudioSession()
        try await analyzer.start(inputSequence: inputs)
        try startCapture()
        isRunning = true
    }

    /// Stops capture and flushes the in-flight phrase as finalized text.
    func finish() async {
        guard isRunning else { return }
        stopCapture()
        inputBuilder?.finish()
        inputBuilder = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        let pendingResults = resultsTask
        await pendingResults?.value
        resultsTask = nil
        await teardown()
    }

    /// Stops capture and drops any phrase that has not already finalized.
    func cancel() async {
        if isRunning { stopCapture() }
        inputBuilder?.finish()
        inputBuilder = nil
        await analyzer?.cancelAndFinishNow()
        await teardown()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // T3 Vision can move to the background when another app opens an
        // immersive space. A mixable input/output session keeps that app's
        // audio audible while this already-active recording continues.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    private func startCapture() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer: buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopCapture() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func append(buffer: AVAudioPCMBuffer) {
        guard let inputBuilder, let analyzerFormat,
              let converted = convert(buffer: buffer, to: analyzerFormat) else { return }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.outputFormat != format || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
              let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
              ) else { return nil }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func teardown() async {
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}
