import AVFoundation
import Foundation
import Speech

/// SpeechAnalyzer-backed dictation, iOS 26+.
///
/// Preferred over `LegacyDictationEngine` because it is the only path that
/// supports contextual vocabulary. Seeding project names, branch names and
/// provider names through `AnalysisContext.contextualStrings` is the difference
/// between "use the ThreadComposer atom" transcribing correctly and it coming
/// back as noise.
@available(iOS 26.0, *)
final class ModernDictationEngine: DictationEngine {
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
  private var resultsTask: Task<Void, Never>?
  private var converter: AVAudioConverter?
  private var analyzerFormat: AVAudioFormat?

  func start(contextualStrings: [String], callbacks: DictationCallbacks) async throws {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
      throw DictationError.localeUnsupported
    }

    // `.volatileResults` is what produces the in-flight text for the HUD. Without
    // it the transcriber only emits finalized phrases and the UI looks frozen
    // while you speak.
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: []
    )
    self.transcriber = transcriber

    // Models are shared across apps and persist between launches, so this is
    // usually a no-op after the first run. It can be a real download the first
    // time, which is why the JS side shows a preparing state.
    try await AssetInventory.reserve(locale: locale)
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await installation.downloadAndInstall()
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.analyzer = analyzer

    if !contextualStrings.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings = [.general: contextualStrings]
      try await analyzer.setContext(context)
    }

    analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

    let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
    self.inputBuilder = inputBuilder

    resultsTask = Task {
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          if text.isEmpty { continue }
          if result.isFinal {
            callbacks.onFinalized(text)
          } else {
            callbacks.onVolatile(text)
          }
        }
      } catch is CancellationError {
        // Expected when the session is cancelled.
      } catch {
        callbacks.onError(error.localizedDescription)
      }
    }

    // Autonomous analysis: returns immediately and consumes the stream on a task
    // the analyzer owns, which suits live microphone input.
    try await analyzer.start(inputSequence: inputSequence)
  }

  func append(buffer: AVAudioPCMBuffer) {
    guard let inputBuilder, let analyzerFormat else { return }

    guard let converted = convert(buffer: buffer, to: analyzerFormat) else { return }
    inputBuilder.yield(AnalyzerInput(buffer: converted))
  }

  private func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    if buffer.format == format {
      return buffer
    }
    if converter?.outputFormat != format || converter?.inputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: format)
    }
    guard let converter else { return nil }

    // Ratio-scaled capacity, rounded up, so a downsample never truncates the
    // tail of a buffer.
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
    guard capacity > 0,
          let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return nil
    }

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
    if conversionError != nil || output.frameLength == 0 {
      return nil
    }
    return output
  }

  func finish() async {
    inputBuilder?.finish()
    inputBuilder = nil
    // Flushes the in-flight phrase as a final result, so the last thing said
    // still reaches the composer.
    try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    await teardown()
  }

  func cancel() async {
    inputBuilder?.finish()
    inputBuilder = nil
    await analyzer?.cancelAndFinishNow()
    await teardown()
  }

  private func teardown() async {
    resultsTask?.cancel()
    resultsTask = nil
    analyzer = nil
    transcriber = nil
    converter = nil
    analyzerFormat = nil
  }
}
