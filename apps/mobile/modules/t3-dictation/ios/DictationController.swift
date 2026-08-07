import AVFoundation
import Foundation
import Speech

/// Owns the microphone and whichever recognition engine is appropriate for the
/// OS, so the Expo module surface stays thin.
final class DictationController {
  private let audioEngine = AVAudioEngine()
  private var engine: DictationEngine?
  private let stateQueue = DispatchQueue(label: "com.t3tools.dictation.state")
  private var isRunning = false

  var onVolatile: ((String) -> Void)?
  var onFinalized: ((String) -> Void)?
  var onError: ((String) -> Void)?

  static var isAvailable: Bool {
    if #available(iOS 26.0, *) {
      return true
    }
    return SFSpeechRecognizer(locale: Locale.current)?.isAvailable ?? false
  }

  /// True when the OS can bias recognition toward supplied vocabulary in the
  /// richer `AnalysisContext` sense. The JS side uses this to decide whether
  /// gathering project/branch vocabulary is worth the work.
  static var supportsContextualVocabulary: Bool {
    if #available(iOS 26.0, *) {
      return true
    }
    return false
  }

  // MARK: - Permissions

  static func requestPermissions() async -> Bool {
    let microphoneGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
    guard microphoneGranted else { return false }

    // SpeechAnalyzer runs on device and does not require this authorization, so
    // a refusal there only blocks the pre-26 fallback. Asking unconditionally
    // keeps the prompt in one place.
    let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }

    if #available(iOS 26.0, *) {
      return true
    }
    return speechStatus == .authorized
  }

  // MARK: - Session

  func start(contextualStrings: [String]) async throws {
    guard !isRunning else { return }

    let callbacks = DictationCallbacks(
      onVolatile: { [weak self] text in self?.onVolatile?(text) },
      onFinalized: { [weak self] text in self?.onFinalized?(text) },
      onError: { [weak self] message in self?.onError?(message) }
    )

    let engine: DictationEngine
    if #available(iOS 26.0, *) {
      engine = ModernDictationEngine()
    } else {
      engine = LegacyDictationEngine()
    }
    self.engine = engine

    try configureAudioSession()
    try await engine.start(contextualStrings: contextualStrings, callbacks: callbacks)
    try startCapture(feeding: engine)
    isRunning = true
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    // .record rather than .playAndRecord: nothing in the app plays audio during
    // dictation, and .record leaves the route alone. Ducking keeps background
    // media audible but quiet while talking.
    try session.setCategory(.record, mode: .default, options: [.duckOthers, .allowBluetoothHFP])
    try session.setActive(true, options: [])
  }

  private func startCapture(feeding engine: DictationEngine) throws {
    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
      engine.append(buffer: buffer)
    }

    audioEngine.prepare()
    try audioEngine.start()
  }

  /// Stops capture and flushes the in-flight phrase into a final result.
  func stop() async {
    guard isRunning else { return }
    stopCapture()
    await engine?.finish()
    finishSession()
  }

  /// Stops capture and drops anything not already delivered.
  func cancel() async {
    guard isRunning else { return }
    stopCapture()
    await engine?.cancel()
    finishSession()
  }

  private func stopCapture() {
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    audioEngine.inputNode.removeTap(onBus: 0)
  }

  private func finishSession() {
    engine = nil
    isRunning = false
    // Leaving the session active would keep other apps ducked after dictation
    // ends, which is very noticeable when music is playing.
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }
}
