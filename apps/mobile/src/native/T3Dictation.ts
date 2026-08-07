import { requireOptionalNativeModule } from "expo";

/**
 * Structural stand-in for expo-modules-core's `EventSubscription`. Declared here
 * rather than imported because expo-modules-core is a transitive dependency, and
 * `remove()` is the entire surface used.
 */
export interface DictationSubscription {
  remove: () => void;
}

/**
 * Push-to-talk dictation, backed by SpeechAnalyzer on iOS 26+ and
 * SFSpeechRecognizer below that.
 *
 * `requireOptionalNativeModule` rather than the required variant: the module is
 * absent in Expo Go and in any dev client built before it was added, and the
 * push-to-talk overlay simply hides in that case rather than crashing the app.
 */
interface NativeDictationModule {
  isAvailable: () => boolean;
  supportsContextualVocabulary: () => boolean;
  requestPermissions: () => Promise<boolean>;
  start: (contextualStrings: ReadonlyArray<string>) => Promise<void>;
  stop: () => Promise<void>;
  cancel: () => Promise<void>;
  addListener: <A>(event: string, listener: (payload: A) => void) => DictationSubscription;
}

const nativeModule = requireOptionalNativeModule<NativeDictationModule>("T3Dictation");

export interface DictationTextEvent {
  readonly text: string;
}

export interface DictationErrorEvent {
  readonly message: string;
}

export function isDictationSupported(): boolean {
  try {
    return nativeModule?.isAvailable() ?? false;
  } catch {
    return false;
  }
}

export function supportsContextualVocabulary(): boolean {
  try {
    return nativeModule?.supportsContextualVocabulary() ?? false;
  } catch {
    return false;
  }
}

export async function requestDictationPermissions(): Promise<boolean> {
  return (await nativeModule?.requestPermissions()) ?? false;
}

export async function startDictation(contextualStrings: ReadonlyArray<string>): Promise<void> {
  await nativeModule?.start(contextualStrings);
}

/** Ends the session, flushing the in-flight phrase as a final result. */
export async function stopDictation(): Promise<void> {
  await nativeModule?.stop();
}

/** Ends the session and discards anything not already delivered. */
export async function cancelDictation(): Promise<void> {
  await nativeModule?.cancel();
}

/** Tentative text, still being revised. Show it; never commit it. */
export function addVolatileListener(
  listener: (event: DictationTextEvent) => void,
): DictationSubscription | null {
  return nativeModule?.addListener<DictationTextEvent>("onVolatile", listener) ?? null;
}

/** A settled phrase. Safe to commit into the composer draft. */
export function addFinalizedListener(
  listener: (event: DictationTextEvent) => void,
): DictationSubscription | null {
  return nativeModule?.addListener<DictationTextEvent>("onFinalized", listener) ?? null;
}

export function addDictationErrorListener(
  listener: (event: DictationErrorEvent) => void,
): DictationSubscription | null {
  return nativeModule?.addListener<DictationErrorEvent>("onError", listener) ?? null;
}
