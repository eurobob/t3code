import AVFoundation
import Foundation
import OSLog
import Speech

private final class VisionSystemSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(
            start: channel,
            count: Int(buffer.frameLength)
        ))
        lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// Apple's native transcription path. It remains available while WhisperKit
/// models prepare and provides volatile and finalized phrases in real time.
final class VisionSystemDictationController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.t3tools.t3code.vision",
        category: "Dictation"
    )

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var sampleConverter: AVAudioConverter?
    private var sampleFormat: AVAudioFormat?
    private let sampleStore = VisionSystemSampleStore()
    private var isRunning = false

    var onVolatile: (@MainActor @Sendable (String) -> Void)?
    var onFinalized: (@MainActor @Sendable (String) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?

    func start(contextualStrings: [String]) async throws {
        guard !isRunning else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale.current
        ) else {
            throw VisionDictationError.localeUnsupported
        }
        Self.logger.notice(
            "[system] preparing SpeechAnalyzer for \(locale.identifier, privacy: .public) with \(contextualStrings.count, privacy: .public) context entries"
        )
        Self.recordDiagnostic(
            "System dictation: preparing \(locale.identifier) with \(contextualStrings.count) context entries"
        )

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        let assetsStartedAt = Date()
        try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            Self.recordDiagnostic("System dictation: speech assets installation started")
            Self.logger.notice("[system] SpeechAnalyzer asset installation started")
            try await installation.downloadAndInstall()
            Self.recordDiagnostic(
                "System dictation: speech assets installed in \(Self.secondsSince(assetsStartedAt))s"
            )
            Self.logger.notice(
                "[system] SpeechAnalyzer asset installation finished in \(Date().timeIntervalSince(assetsStartedAt), format: .fixed(precision: 2))s"
            )
        } else {
            Self.recordDiagnostic("System dictation: speech assets already available")
            Self.logger.notice("[system] SpeechAnalyzer assets already available")
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
        sampleFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        sampleStore.reset()
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder = continuation

        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        Self.logger.notice(
                            "[system] finalized result with \(text.count, privacy: .public) characters"
                        )
                        self?.onFinalized?(text)
                    } else {
                        self?.onVolatile?(text)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "[system] result stream failed: \(error.localizedDescription, privacy: .public)"
                )
                self?.onError?(error.localizedDescription)
            }
        }

        try configureAudioSession()
        try await analyzer.start(inputSequence: inputs)
        try startCapture()
        isRunning = true
        Self.recordDiagnostic("System dictation: analyzer and audio engine started")
        Self.logger.notice("[system] SpeechAnalyzer and audio engine started")
    }

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
        Self.recordDiagnostic("System dictation: finalized and stopped")
        Self.logger.notice("[system] SpeechAnalyzer finalized and stopped")
    }

    func cancel() async {
        if isRunning { stopCapture() }
        inputBuilder?.finish()
        inputBuilder = nil
        await analyzer?.cancelAndFinishNow()
        await teardown()
    }

    func snapshotSamples() -> [Float] {
        sampleStore.snapshot()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
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
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
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
        if let inputBuilder, let analyzerFormat,
           let converted = convertForAnalyzer(buffer: buffer, to: analyzerFormat) {
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }
        if let sampleFormat,
           let converted = convertForSamples(buffer: buffer, to: sampleFormat) {
            sampleStore.append(converted)
        }
    }

    private func convertForAnalyzer(
        buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if analyzerConverter?.outputFormat != format
            || analyzerConverter?.inputFormat != buffer.format {
            analyzerConverter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let analyzerConverter else { return nil }

        return convert(
            buffer: buffer,
            to: format,
            using: analyzerConverter
        )
    }

    private func convertForSamples(
        buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if sampleConverter?.outputFormat != format
            || sampleConverter?.inputFormat != buffer.format {
            sampleConverter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let sampleConverter else { return nil }

        return convert(
            buffer: buffer,
            to: format,
            using: sampleConverter
        )
    }

    private func convert(
        buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {

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
        analyzerConverter = nil
        analyzerFormat = nil
        sampleConverter = nil
        sampleFormat = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private static func recordDiagnostic(_ message: String) {
        Task { @MainActor in
            VisionDictationDiagnostics.shared.record(message)
        }
    }

    private static func secondsSince(_ date: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(date))
    }
}
