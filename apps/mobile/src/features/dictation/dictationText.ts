/**
 * Pure text arithmetic for committing and rolling back dictated speech.
 *
 * Kept separate from the session hook because the rollback rule is the one
 * piece of this feature that can silently destroy the user's typing, so it is
 * worth testing directly.
 */

export interface DictationAppend {
  readonly next: string;
  /** Exactly what was added, including any separator. Rollback needs this verbatim. */
  readonly appended: string;
}

/**
 * Appends a finalized phrase, inserting a separator only when one is actually
 * needed. The separator is part of `appended` so that rolling back removes the
 * spacing too and does not leave a trailing gap.
 */
export function appendDictatedText(existing: string, phrase: string): DictationAppend {
  const trimmed = phrase.trim();
  if (trimmed.length === 0) {
    return { next: existing, appended: "" };
  }
  if (existing.length === 0) {
    return { next: trimmed, appended: trimmed };
  }
  const needsSpace = !/\s$/.test(existing);
  const appended = needsSpace ? ` ${trimmed}` : trimmed;
  return { next: `${existing}${appended}`, appended };
}

/**
 * Removes text this dictation session committed.
 *
 * Only strips when the draft still ends with exactly what was appended. If the
 * user edited mid-dictation — moved the cursor, deleted a word, typed after the
 * transcript — the suffix no longer matches and the draft is left completely
 * alone. Losing a cancelled transcript is a shrug; eating something the user
 * typed is not, so this deliberately fails toward keeping text.
 */
export function rollbackDictatedText(existing: string, appended: string): string {
  if (appended.length === 0 || !existing.endsWith(appended)) {
    return existing;
  }
  return existing.slice(0, existing.length - appended.length);
}
