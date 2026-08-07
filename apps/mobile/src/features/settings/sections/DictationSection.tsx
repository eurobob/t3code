import { useAtomSet, useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import { useMemo } from "react";
import { Platform, View } from "react-native";

import { AppText as Text } from "../../../components/AppText";
import { isDictationSupported } from "../../../native/T3Dictation";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../../state/preferences";
import { SettingsSection } from "../components/SettingsSection";
import { SettingsSwitchRow } from "../components/SettingsSwitchRow";

/**
 * The two rows have independent availability. Hiding the keyboard serves system
 * Voice Control and needs nothing from us beyond iOS, whereas push-to-talk needs
 * the native module — which is absent on Android and in dev clients built before
 * it existed. Showing a dead push-to-talk toggle would be worse than omitting
 * it, but hiding the whole section would take the Voice Control setting with it.
 */
export function DictationSection() {
  const pushToTalkSupported = useMemo(() => isDictationSupported(), []);
  const preferencesResult = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const preferences = AsyncResult.isSuccess(preferencesResult) ? preferencesResult.value : null;

  if (Platform.OS !== "ios") {
    return null;
  }

  const dictationEnabled = preferences?.dictationEnabled ?? true;
  const keyboardHidden = preferences?.composerSoftwareKeyboardHidden ?? false;

  return (
    <View className="gap-3">
      <SettingsSection title="Dictation">
        {pushToTalkSupported ? (
          <SettingsSwitchRow
            icon="mic.fill"
            label="Push-to-Talk Button"
            value={dictationEnabled}
            onValueChange={(value) => savePreferences({ dictationEnabled: value })}
          />
        ) : null}
        <SettingsSwitchRow
          icon="keyboard"
          label="Hide On-Screen Keyboard"
          value={keyboardHidden}
          onValueChange={(value) => savePreferences({ composerSoftwareKeyboardHidden: value })}
        />
      </SettingsSection>
      {pushToTalkSupported ? (
        <Text className="px-2 text-sm text-foreground-muted">
          Hold the floating button to dictate into the current task. Slide up to keep it listening
          hands-free, or slide inward to discard. Drag the handle beside it to move it.
        </Text>
      ) : null}
      <Text className="px-2 text-sm text-foreground-muted">
        Hiding the on-screen keyboard keeps the composer focused without the keyboard covering the
        screen, so iPadOS Voice Control can dictate straight into it — including its attention-aware
        mode. Hardware keyboards keep working. Turn it off any time to get the keyboard back.
      </Text>
    </View>
  );
}
