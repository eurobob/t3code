import { useCallback, useEffect, useRef, useState } from "react";

import {
  addDictationErrorListener,
  addFinalizedListener,
  addVolatileListener,
  cancelDictation,
  requestDictationPermissions,
  startDictation,
  stopDictation,
} from "../../native/T3Dictation";
import { getComposerDraftSnapshot, setComposerDraftText } from "../../state/use-composer-drafts";
import { appendDictatedText, rollbackDictatedText } from "./dictationText";
import { currentDictationVocabulary } from "./dictationVocabulary";
import { getDictationTarget } from "./dictationTarget";

export type DictationPhase =
  /** Not recording. */
  | "idle"
  /** Permissions and, on first use of a locale, a model download. */
  | "preparing"
  /** Recording, finger still down. */
  | "listening"
  /** Recording hands-free after a drag-up. */
  | "latched";

export interface DictationSession {
  readonly phase: DictationPhase;
  /** In-flight text for the HUD. Never committed. */
  readonly volatileText: string;
  readonly error: string | null;
  readonly begin: () => void;
  readonly latch: () => void;
  /** Stops and keeps everything committed so far, plus the in-flight phrase. */
  readonly commitAndStop: () => void;
  /** Stops and removes everything this session committed. */
  readonly abort: () => void;
  readonly dismissError: () => void;
}

export function useDictationSession(): DictationSession {
  const [phase, setPhase] = useState<DictationPhase>("idle");
  const [volatileText, setVolatileText] = useState("");
  const [error, setError] = useState<string | null>(null);

  /**
   * Captured when the session starts rather than read per phrase: if navigation
   * changes the active composer mid-utterance, the rest of the sentence should
   * still land where the user was looking when they started talking.
   */
  const draftKeyRef = useRef<string | null>(null);
  /** Everything this session appended, verbatim, so abort can undo exactly it. */
  const committedRef = useRef("");
  /** Guards against a finalized phrase arriving after an abort. */
  const activeRef = useRef(false);

  const commitPhrase = useCallback((phrase: string) => {
    const draftKey = draftKeyRef.current;
    if (!activeRef.current || draftKey === null) {
      return;
    }
    const existing = getComposerDraftSnapshot(draftKey).text;
    const { next, appended } = appendDictatedText(existing, phrase);
    if (appended.length === 0) {
      return;
    }
    setComposerDraftText(draftKey, next);
    committedRef.current += appended;
    // The phrase is settled, so anything the HUD was showing for it is stale.
    setVolatileText("");
  }, []);

  useEffect(() => {
    const volatileSubscription = addVolatileListener(({ text }) => {
      if (activeRef.current) {
        setVolatileText(text);
      }
    });
    const finalizedSubscription = addFinalizedListener(({ text }) => {
      commitPhrase(text);
    });
    const errorSubscription = addDictationErrorListener(({ message }) => {
      activeRef.current = false;
      setPhase("idle");
      setVolatileText("");
      setError(message);
    });

    return () => {
      volatileSubscription?.remove();
      finalizedSubscription?.remove();
      errorSubscription?.remove();
    };
  }, [commitPhrase]);

  const begin = useCallback(() => {
    if (activeRef.current) {
      return;
    }
    const target = getDictationTarget();
    if (target === null) {
      setError("Open a task to dictate into.");
      return;
    }

    activeRef.current = true;
    draftKeyRef.current = target.draftKey;
    committedRef.current = "";
    setVolatileText("");
    setError(null);
    setPhase("preparing");

    void (async () => {
      try {
        const granted = await requestDictationPermissions();
        if (!granted) {
          activeRef.current = false;
          setPhase("idle");
          setError("Microphone access is needed to dictate.");
          return;
        }
        await startDictation(currentDictationVocabulary());
        // A release or cancel can land while start() is still awaiting; in that
        // case the session is already over and must not be shown as listening.
        if (!activeRef.current) {
          await cancelDictation();
          return;
        }
        setPhase((current) => (current === "preparing" ? "listening" : current));
      } catch (cause) {
        activeRef.current = false;
        setPhase("idle");
        setError(cause instanceof Error ? cause.message : String(cause));
      }
    })();
  }, []);

  const latch = useCallback(() => {
    setPhase((current) =>
      current === "listening" || current === "preparing" ? "latched" : current,
    );
  }, []);

  const commitAndStop = useCallback(() => {
    if (!activeRef.current) {
      return;
    }
    // The UI stops showing a live session immediately, but the session stays
    // active until the native flush resolves: stopDictation finalizes the
    // in-flight phrase, and that last onFinalized has to be allowed through
    // commitPhrase or the final few words are silently dropped.
    setPhase("idle");
    setVolatileText("");
    void (async () => {
      try {
        await stopDictation();
      } finally {
        activeRef.current = false;
        committedRef.current = "";
      }
    })();
  }, []);

  const abort = useCallback(() => {
    if (!activeRef.current) {
      return;
    }
    activeRef.current = false;
    setPhase("idle");
    setVolatileText("");

    const draftKey = draftKeyRef.current;
    const committed = committedRef.current;
    committedRef.current = "";

    void cancelDictation();

    if (draftKey !== null && committed.length > 0) {
      const existing = getComposerDraftSnapshot(draftKey).text;
      setComposerDraftText(draftKey, rollbackDictatedText(existing, committed));
    }
  }, []);

  const dismissError = useCallback(() => setError(null), []);

  // Leaving the screen mid-session would otherwise strand the microphone on.
  useEffect(
    () => () => {
      if (activeRef.current) {
        activeRef.current = false;
        void cancelDictation();
      }
    },
    [],
  );

  return { phase, volatileText, error, begin, latch, commitAndStop, abort, dismissError };
}
