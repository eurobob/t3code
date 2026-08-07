import { useAtomValue } from "@effect/atom-react";
import { useFocusEffect } from "@react-navigation/native";
import { Atom } from "effect/unstable/reactivity";
import { useCallback } from "react";

import { appAtomRegistry } from "../../state/atom-registry";

/**
 * Where dictated text should land.
 *
 * The push-to-talk button is global — it floats above navigation — but the
 * composer it writes into is whichever screen is in front. Screens register
 * themselves rather than the overlay deriving the target, because the two
 * composers come from different places: an open thread's draft key is derived
 * from the selected thread, while the new-task flow owns its own draft key
 * inside a provider the overlay cannot see.
 */
export interface DictationTarget {
  readonly draftKey: string;
  /** Shown in the HUD so it is obvious where words are going. */
  readonly label: string;
}

export const dictationTargetAtom = Atom.make<DictationTarget | null>(null).pipe(
  Atom.keepAlive,
  Atom.withLabel("mobile:dictation-target"),
);

export function getDictationTarget(): DictationTarget | null {
  return appAtomRegistry.get(dictationTargetAtom);
}

export function useDictationTarget(): DictationTarget | null {
  return useAtomValue(dictationTargetAtom);
}

/**
 * Claims the dictation target while this screen is focused.
 *
 * Clearing on blur checks ownership first: on iPad the sidebar and detail panes
 * are mounted together and blur can arrive after the next screen has already
 * registered, which would otherwise leave the overlay with no target.
 */
export function useRegisterDictationTarget(target: DictationTarget | null): void {
  const draftKey = target?.draftKey ?? null;
  const label = target?.label ?? "";

  useFocusEffect(
    useCallback(() => {
      if (draftKey === null) {
        return;
      }
      const claimed: DictationTarget = { draftKey, label };
      appAtomRegistry.set(dictationTargetAtom, claimed);

      return () => {
        const current = appAtomRegistry.get(dictationTargetAtom);
        if (current?.draftKey === claimed.draftKey) {
          appAtomRegistry.set(dictationTargetAtom, null);
        }
      };
    }, [draftKey, label]),
  );
}
