import ExpoModulesCore
import Foundation

public final class T3DictationModule: Module {
  private let controller = DictationController()

  public func definition() -> ModuleDefinition {
    Name("T3Dictation")

    Events("onVolatile", "onFinalized", "onError")

    OnCreate {
      self.controller.onVolatile = { [weak self] text in
        self?.sendEvent("onVolatile", ["text": text])
      }
      self.controller.onFinalized = { [weak self] text in
        self?.sendEvent("onFinalized", ["text": text])
      }
      self.controller.onError = { [weak self] message in
        self?.sendEvent("onError", ["message": message])
      }
    }

    Function("isAvailable") { () -> Bool in
      DictationController.isAvailable
    }

    Function("supportsContextualVocabulary") { () -> Bool in
      DictationController.supportsContextualVocabulary
    }

    AsyncFunction("requestPermissions") { () -> Bool in
      await DictationController.requestPermissions()
    }

    /// `contextualStrings` biases recognition toward vocabulary the user is
    /// likely to say — project names, branch names, provider names. Ignored by
    /// the pre-26 fallback beyond simple phrase biasing.
    AsyncFunction("start") { (contextualStrings: [String]) in
      try await self.controller.start(contextualStrings: contextualStrings)
    }

    AsyncFunction("stop") {
      await self.controller.stop()
    }

    AsyncFunction("cancel") {
      await self.controller.cancel()
    }

    OnDestroy {
      // The module can be torn down mid-session on a reload; leaving the audio
      // session active would keep the mic indicator lit.
      let controller = self.controller
      Task { await controller.cancel() }
    }
  }
}
