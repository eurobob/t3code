import AVFoundation
import Foundation

/// What the module reports back to JavaScript while a dictation session runs.
///
/// The split between volatile and finalized is the whole point of this module.
/// Volatile text is still being revised and is only ever shown in the HUD;
/// finalized text is committed into the composer draft as it arrives, which is
/// what makes dictation feel real-time without the draft churning.
struct DictationCallbacks {
  let onVolatile: (String) -> Void
  let onFinalized: (String) -> Void
  let onError: (String) -> Void
}

protocol DictationEngine: AnyObject {
  /// Prepares models and starts a session. May block on a model download the
  /// first time a locale is used.
  func start(contextualStrings: [String], callbacks: DictationCallbacks) async throws

  /// Feeds one buffer captured from the input node, in the tap's own format.
  /// Each engine converts internally, because they want different formats.
  func append(buffer: AVAudioPCMBuffer)

  /// Ends the session and flushes any pending phrase as a final result.
  func finish() async

  /// Ends the session and discards anything not already delivered.
  func cancel() async
}

enum DictationError: LocalizedError {
  case localeUnsupported
  case recognizerUnavailable
  case microphonePermissionDenied
  case speechPermissionDenied

  var errorDescription: String? {
    switch self {
    case .localeUnsupported:
      return "Dictation does not support this device's language yet."
    case .recognizerUnavailable:
      return "Speech recognition is unavailable on this device."
    case .microphonePermissionDenied:
      return "T3 Code needs microphone access to dictate."
    case .speechPermissionDenied:
      return "T3 Code needs speech recognition access to dictate."
    }
  }
}
