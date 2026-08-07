import { useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import { Platform } from "react-native";

import { mobilePreferencesAtom } from "./preferences";

/**
 * Whether the composer should stay focused while hiding the on-screen keyboard.
 *
 * This exists to make system Voice Control the primary input method. Voice
 * Control dictates into the *focused* text field, so the composer must keep
 * focus — the thing that needs to go is the keyboard it drags on screen, which
 * covers half an iPad for an input the user intends to speak into.
 *
 * Suppressing focus instead would be the intuitive fix and is exactly wrong: it
 * removes the target Voice Control dictates into.
 *
 * iOS only. The implementation swaps in a zero-height `inputView` on the native
 * composer, which has no Android equivalent.
 */
export function useComposerSoftwareKeyboardHidden(): boolean {
  const preferencesResult = useAtomValue(mobilePreferencesAtom);
  const preferences = AsyncResult.isSuccess(preferencesResult) ? preferencesResult.value : null;
  return Platform.OS === "ios" && (preferences?.composerSoftwareKeyboardHidden ?? false);
}
