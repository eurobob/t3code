import AVFoundation
import Foundation
import Speech

/// SFSpeechRecognizer fallback for iOS 18–25.
///
/// Deliberately degraded compared to `ModernDictationEngine`: SFSpeechRecognizer
/// reports a single cumulative transcription that it keeps revising in place,
/// rather than a sequence of individually finalized phrases. Committing a
/// "stable prefix" from that would risk duplicating or contradicting words the
/// recognizer later revises, so this engine treats everything as volatile and
/// commits once at the end of the session.
///
/// The practical effect: on iOS 26 text lands in the composer as you speak; below
/// that it lands when you stop. Contextual vocabulary is unavailable here too.
final class LegacyDictationEngine: DictationEngine {
  private let recognizer = SFSpeechRecognizer(locale: Locale.current)
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var callbacks: DictationCallbacks?
  private var latestTranscript = ""
  private var didCommit = false
  private var finishContinuation: CheckedContinuation<Void, Never>?

  func start(contextualStrings: [String], callbacks: DictationCallbacks) async throws {
    guard let recognizer, recognizer.isAvailable else {
      throw DictationError.recognizerUnavailable
    }

    self.callbacks = callbacks
    latestTranscript = ""
    didCommit = false

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    // SFSpeechRecognizer has no equivalent of AnalysisContext, but it does take
    // a plain phrase-biasing list, which recovers some of the accuracy.
    request.contextualStrings = contextualStrings
    self.request = request

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }

      if let result {
        self.latestTranscript = result.bestTranscription.formattedString
        if result.isFinal {
          self.commitFinalTranscript()
          return
        }
        if !self.latestTranscript.isEmpty {
          callbacks.onVolatile(self.latestTranscript)
        }
      }

      if let error {
        // A cancelled task reports an error too; that path is handled by cancel().
        if !self.didCommit {
          callbacks.onError(error.localizedDescription)
          self.didCommit = true
        }
        self.resumeFinish()
      }
    }
  }

  private func commitFinalTranscript() {
    guard !didCommit else { return }
    didCommit = true
    let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      callbacks?.onFinalized(text)
    }
    resumeFinish()
  }

  private func resumeFinish() {
    finishContinuation?.resume()
    finishContinuation = nil
  }

  func append(buffer: AVAudioPCMBuffer) {
    request?.append(buffer)
  }

  func finish() async {
    guard task != nil else { return }
    // endAudio makes the recognizer emit its final result; wait for it so the
    // last words are not dropped.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      finishContinuation = continuation
      request?.endAudio()
    }
    teardown()
  }

  func cancel() async {
    didCommit = true
    task?.cancel()
    resumeFinish()
    teardown()
  }

  private func teardown() {
    task = nil
    request = nil
    callbacks = nil
    latestTranscript = ""
  }
}
