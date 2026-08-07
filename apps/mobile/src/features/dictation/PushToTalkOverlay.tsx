import { useAtomSet, useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import * as Haptics from "expo-haptics";
import { useCallback, useMemo, useRef } from "react";
import { Platform, View, useWindowDimensions } from "react-native";
import { Gesture, GestureDetector } from "react-native-gesture-handler";
import Animated, {
  runOnJS,
  useAnimatedStyle,
  useSharedValue,
  withSpring,
  withTiming,
} from "react-native-reanimated";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AppText as Text } from "../../components/AppText";
import { SymbolView } from "../../components/AppSymbol";
import { OverlayPortal } from "../../components/OverlayPortal";
import { isDictationSupported } from "../../native/T3Dictation";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../state/preferences";
import { useThemeColor } from "../../lib/useThemeColor";
import { useDictationTarget } from "./dictationTarget";
import { useDictationSession } from "./useDictationSession";

const BUTTON_SIZE = 64;
const EDGE_MARGIN = 12;
const GRIP_WIDTH = 22;

/** Drag up past this to keep recording hands-free after releasing. */
const LATCH_DISTANCE = 72;
/** Drag inward (away from the screen edge) past this to discard. */
const CANCEL_DISTANCE = 96;

const DEFAULT_POSITION = { edge: "right" as const, y: 0.62 };

type Edge = "left" | "right";

export function PushToTalkOverlay() {
  // The native module is absent in Expo Go and in dev clients built before this
  // feature existed, so the overlay has to be able to simply not exist.
  const supported = useMemo(() => isDictationSupported(), []);
  const preferencesResult = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const preferences = AsyncResult.isSuccess(preferencesResult) ? preferencesResult.value : null;

  const target = useDictationTarget();
  const session = useDictationSession();

  const enabled = preferences?.dictationEnabled ?? true;
  const position = preferences?.dictationButtonPosition ?? DEFAULT_POSITION;

  if (!supported || !enabled) {
    return null;
  }

  return (
    <OverlayPortal>
      <PushToTalkButton
        edge={position.edge}
        y={position.y}
        hasTarget={target !== null}
        targetLabel={target?.label ?? ""}
        session={session}
        onMove={(next) => savePreferences({ dictationButtonPosition: next })}
      />
    </OverlayPortal>
  );
}

function PushToTalkButton(props: {
  readonly edge: Edge;
  readonly y: number;
  readonly hasTarget: boolean;
  readonly targetLabel: string;
  readonly session: ReturnType<typeof useDictationSession>;
  readonly onMove: (position: { readonly edge: Edge; readonly y: number }) => void;
}) {
  const { session } = props;
  const { width, height } = useWindowDimensions();
  const insets = useSafeAreaInsets();

  const accent = String(useThemeColor("--color-primary"));
  const danger = String(useThemeColor("--color-destructive"));
  const surface = String(useThemeColor("--color-surface"));
  const border = String(useThemeColor("--color-border"));
  const onAccent = String(useThemeColor("--color-primary-foreground"));
  const muted = String(useThemeColor("--color-muted-foreground"));
  const foreground = String(useThemeColor("--color-foreground"));

  const usableTop = insets.top + EDGE_MARGIN;
  const usableHeight = Math.max(1, height - usableTop - insets.bottom - EDGE_MARGIN - BUTTON_SIZE);

  const dragX = useSharedValue(0);
  const dragY = useSharedValue(0);
  const cancelArmed = useSharedValue(false);
  const latchArmed = useSharedValue(false);
  const moving = useSharedValue(false);
  const moveTop = useSharedValue(usableTop + props.y * usableHeight);
  const moveStartTop = useSharedValue(0);
  const moveEdge = useSharedValue<Edge>(props.edge);

  // Kept in a ref so the gesture callbacks never capture a stale session.
  const latest = useRef(props);
  latest.current = props;

  const isActive = session.phase === "listening" || session.phase === "preparing";
  const isLatched = session.phase === "latched";

  const haptic = useCallback((style: Haptics.ImpactFeedbackStyle) => {
    if (Platform.OS === "ios") {
      void Haptics.impactAsync(style);
    }
  }, []);

  const beginSession = useCallback(() => {
    latest.current.session.begin();
    haptic(Haptics.ImpactFeedbackStyle.Medium);
  }, [haptic]);

  const endSession = useCallback(
    (outcome: "commit" | "cancel" | "latch") => {
      const current = latest.current.session;
      if (outcome === "cancel") {
        current.abort();
        haptic(Haptics.ImpactFeedbackStyle.Rigid);
        return;
      }
      if (outcome === "latch") {
        current.latch();
        haptic(Haptics.ImpactFeedbackStyle.Heavy);
        return;
      }
      current.commitAndStop();
      haptic(Haptics.ImpactFeedbackStyle.Light);
    },
    [haptic],
  );

  const commitMove = useCallback(
    (edge: Edge, top: number) => {
      const { onMove } = latest.current;
      onMove({ edge, y: Math.min(1, Math.max(0, (top - usableTop) / usableHeight)) });
    },
    [usableHeight, usableTop],
  );

  /**
   * Talk gesture. Recording starts on touch down rather than after a delay,
   * because any hold threshold makes the first word get clipped.
   */
  const talkGesture = useMemo(
    () =>
      Gesture.Pan()
        .minDistance(0)
        .enabled(props.hasTarget)
        .onBegin(() => {
          "worklet";
          dragX.value = 0;
          dragY.value = 0;
          cancelArmed.value = false;
          latchArmed.value = false;
          runOnJS(beginSession)();
        })
        .onUpdate((event) => {
          "worklet";
          dragX.value = event.translationX;
          dragY.value = event.translationY;
          // "Inward" depends on which edge the button is parked against, so the
          // same wrist movement means cancel on either side.
          const inward = moveEdge.value === "right" ? -event.translationX : event.translationX;
          cancelArmed.value = inward >= CANCEL_DISTANCE;
          latchArmed.value = !cancelArmed.value && event.translationY <= -LATCH_DISTANCE;
        })
        .onEnd(() => {
          "worklet";
          if (cancelArmed.value) {
            runOnJS(endSession)("cancel");
          } else if (latchArmed.value) {
            runOnJS(endSession)("latch");
          } else {
            runOnJS(endSession)("commit");
          }
        })
        .onFinalize(() => {
          "worklet";
          dragX.value = withSpring(0, { damping: 18 });
          dragY.value = withSpring(0, { damping: 18 });
          cancelArmed.value = false;
          latchArmed.value = false;
        }),
    [beginSession, cancelArmed, dragX, dragY, endSession, latchArmed, moveEdge, props.hasTarget],
  );

  /**
   * Repositioning lives on its own grip rather than on the button, so that
   * press-to-talk can stay instant. Moving the button is a rare, deliberate act;
   * talking is not.
   */
  const moveGesture = useMemo(
    () =>
      Gesture.Pan()
        .minDistance(4)
        .onBegin(() => {
          "worklet";
          moving.value = true;
          // Anchor to where the drag started and offset by total translation:
          // accumulating per-frame deltas drifts, and this version of
          // gesture-handler does not expose a per-frame change on Pan.
          moveStartTop.value = moveTop.value;
        })
        .onUpdate((event) => {
          "worklet";
          moveTop.value = Math.min(
            usableTop + usableHeight,
            Math.max(usableTop, moveStartTop.value + event.translationY),
          );
          // Snap side as soon as the finger crosses the midline, so the button
          // follows the drag rather than jumping only on release.
          moveEdge.value = event.absoluteX > width / 2 ? "right" : "left";
        })
        .onEnd(() => {
          "worklet";
          runOnJS(commitMove)(moveEdge.value, moveTop.value);
        })
        .onFinalize(() => {
          "worklet";
          moving.value = false;
        }),
    [commitMove, moveEdge, moveStartTop, moveTop, moving, usableHeight, usableTop, width],
  );

  const containerStyle = useAnimatedStyle(() => ({
    top: moving.value ? moveTop.value : withTiming(moveTop.value, { duration: 140 }),
    left: moveEdge.value === "left" ? EDGE_MARGIN : undefined,
    right: moveEdge.value === "right" ? EDGE_MARGIN : undefined,
    transform: [{ translateX: dragX.value }, { translateY: dragY.value }],
  }));

  const buttonStyle = useAnimatedStyle(() => ({
    backgroundColor: cancelArmed.value ? danger : accent,
    transform: [{ scale: withTiming(latchArmed.value ? 1.12 : 1, { duration: 120 }) }],
  }));

  const showHud = isActive || isLatched;

  return (
    <>
      {showHud ? (
        <DictationHud
          border={border}
          foreground={foreground}
          muted={muted}
          surface={surface}
          phase={session.phase}
          targetLabel={props.targetLabel}
          volatileText={session.volatileText}
        />
      ) : null}

      <Animated.View className="absolute" style={containerStyle} pointerEvents="box-none">
        <View className="flex-row items-center">
          {/* The grip sits on the inward side so it never overlaps the screen edge. */}
          {props.edge === "right" ? (
            <MoveGrip gesture={moveGesture} tint={muted} surface={surface} border={border} />
          ) : null}

          <GestureDetector gesture={talkGesture}>
            <Animated.View
              accessibilityRole="button"
              accessibilityLabel={
                isLatched
                  ? "Stop dictation"
                  : "Hold to dictate. Slide up to lock, slide in to cancel."
              }
              accessibilityState={{ disabled: !props.hasTarget, busy: showHud }}
              className="items-center justify-center rounded-full"
              style={[
                {
                  width: BUTTON_SIZE,
                  height: BUTTON_SIZE,
                  opacity: props.hasTarget ? 1 : 0.4,
                  shadowColor: "#000",
                  shadowOpacity: 0.25,
                  shadowRadius: 8,
                  shadowOffset: { width: 0, height: 3 },
                  elevation: 5,
                },
                buttonStyle,
              ]}
            >
              <SymbolView
                name={isLatched ? "stop.fill" : "mic.fill"}
                size={26}
                tintColor={onAccent}
              />
            </Animated.View>
          </GestureDetector>

          {props.edge === "left" ? (
            <MoveGrip gesture={moveGesture} tint={muted} surface={surface} border={border} />
          ) : null}
        </View>
      </Animated.View>
    </>
  );
}

function MoveGrip(props: {
  readonly gesture: ReturnType<typeof Gesture.Pan>;
  readonly tint: string;
  readonly surface: string;
  readonly border: string;
}) {
  return (
    <GestureDetector gesture={props.gesture}>
      <View
        accessibilityRole="adjustable"
        accessibilityLabel="Move the dictation button"
        // Generous hit slop: the grip is deliberately small so it does not
        // compete with the mic button, which makes it hard to hit precisely.
        hitSlop={{ top: 12, bottom: 12, left: 12, right: 12 }}
        className="items-center justify-center rounded-full"
        style={{
          width: GRIP_WIDTH,
          height: 40,
          marginHorizontal: 2,
          backgroundColor: props.surface,
          borderColor: props.border,
          borderWidth: 1,
        }}
      >
        <SymbolView name="ellipsis" size={14} tintColor={props.tint} />
      </View>
    </GestureDetector>
  );
}

function DictationHud(props: {
  readonly phase: string;
  readonly targetLabel: string;
  readonly volatileText: string;
  readonly surface: string;
  readonly border: string;
  readonly foreground: string;
  readonly muted: string;
}) {
  const insets = useSafeAreaInsets();
  const status =
    props.phase === "preparing"
      ? "Preparing…"
      : props.phase === "latched"
        ? "Listening — tap to stop"
        : "Listening — slide up to lock";

  return (
    <View
      pointerEvents="none"
      className="absolute items-center"
      style={{ left: 16, right: 16, bottom: insets.bottom + 96 }}
    >
      <View
        className="rounded-2xl px-4 py-3"
        style={{
          maxWidth: 520,
          backgroundColor: props.surface,
          borderColor: props.border,
          borderWidth: 1,
        }}
      >
        <Text className="text-xs" style={{ color: props.muted }}>
          {props.targetLabel ? `${status} · ${props.targetLabel}` : status}
        </Text>
        {props.volatileText ? (
          <Text className="mt-1 text-sm" style={{ color: props.foreground }} numberOfLines={3}>
            {props.volatileText}
          </Text>
        ) : null}
      </View>
    </View>
  );
}
