package expo.modules.t3dictation

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

/**
 * Android placeholder.
 *
 * Push-to-talk dictation is currently iOS-only: the feature is built around
 * SpeechAnalyzer's split between volatile and finalized results, which is what
 * lets finalized text commit into the composer mid-utterance. Android's
 * SpeechRecognizer reports a single cumulative transcript instead, so it would
 * need a different interaction design rather than a direct port.
 *
 * Reporting unavailable here makes the JS side hide the push-to-talk overlay
 * entirely, so Android behaves exactly as it did before the feature existed.
 */
class T3DictationModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("T3Dictation")

    Events("onVolatile", "onFinalized", "onError")

    Function("isAvailable") { false }

    Function("supportsContextualVocabulary") { false }

    AsyncFunction("requestPermissions") { false }

    AsyncFunction("start") { _: List<String> -> }

    AsyncFunction("stop") { }

    AsyncFunction("cancel") { }
  }
}
