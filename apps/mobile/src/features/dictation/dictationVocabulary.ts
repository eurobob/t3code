import type { OrchestrationShellSnapshot } from "@t3tools/contracts";
import * as Option from "effect/Option";

import { appAtomRegistry } from "../../state/atom-registry";
import { environmentCatalog } from "../../connection/catalog";
import { environmentShell } from "../../state/shell";

/**
 * Vocabulary fed to the recognizer so it biases toward words the user is
 * actually likely to say.
 *
 * This is the difference between usable dictation and unusable dictation for
 * this app: a general language model has no reason to prefer "Codex" over
 * "codecs", or a branch name over a similar-sounding English phrase. Everything
 * here is cheap to gather from the shell snapshot that is already in memory.
 */

/** Words the model would otherwise mangle, independent of the user's data. */
const STATIC_VOCABULARY: ReadonlyArray<string> = [
  // Providers.
  "Codex",
  "Claude",
  "Claude Code",
  "Cursor",
  "Grok",
  "OpenCode",
  // T3 nouns that recur constantly in instructions.
  "T3",
  "T3 Code",
  "thread",
  "worktree",
  "checkpoint",
  "pull request",
  "rebase",
  "monorepo",
  "TypeScript",
  "Swift",
  "Kotlin",
];

/**
 * Contextual string lists are a biasing hint, not a dictionary — an unbounded
 * list from a large workspace would dilute the signal and cost startup time.
 * Recently-updated threads are the ones being talked about, so the cap favours
 * them.
 */
const MAX_DYNAMIC_TERMS = 200;

function pathBasename(path: string): string {
  const separator = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
  return separator >= 0 ? path.slice(separator + 1) : path;
}

/**
 * Branch names are rarely spoken as-is: "feat/add-dictation" is said as "add
 * dictation". Splitting on separators gives the recognizer the words the user
 * will actually produce.
 */
function spokenFormsOfIdentifier(value: string): ReadonlyArray<string> {
  const spoken = value.replace(/[/_\-.]+/g, " ").trim();
  return spoken.length > 0 && spoken !== value ? [value, spoken] : [value];
}

export function collectVocabularyFromSnapshot(
  snapshot: OrchestrationShellSnapshot,
): ReadonlyArray<string> {
  const terms: Array<string> = [];

  for (const project of snapshot.projects) {
    terms.push(project.title);
    terms.push(...spokenFormsOfIdentifier(pathBasename(project.workspaceRoot)));
  }

  const threadsByRecency = [...snapshot.threads].sort((left, right) =>
    right.updatedAt.localeCompare(left.updatedAt),
  );
  for (const thread of threadsByRecency) {
    terms.push(thread.title);
    if (thread.branch) {
      terms.push(...spokenFormsOfIdentifier(thread.branch));
    }
  }

  return terms;
}

function normalize(terms: ReadonlyArray<string>): ReadonlyArray<string> {
  const seen = new Set<string>();
  const result: Array<string> = [];
  for (const term of terms) {
    const trimmed = term.trim();
    // Single characters and very long strings are noise as biasing hints.
    if (trimmed.length < 2 || trimmed.length > 80) {
      continue;
    }
    const key = trimmed.toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(trimmed);
  }
  return result;
}

/**
 * Reads current vocabulary straight from the atom registry rather than through
 * hooks, because it is gathered at the moment dictation starts — not on every
 * render of the overlay.
 */
export function currentDictationVocabulary(): ReadonlyArray<string> {
  const dynamic: Array<string> = [];
  try {
    const catalog = appAtomRegistry.get(environmentCatalog.catalogValueAtom);
    for (const environmentId of catalog.entries.keys()) {
      const state = appAtomRegistry.get(environmentShell.stateValueAtom(environmentId));
      if (Option.isNone(state.snapshot)) {
        continue;
      }
      dynamic.push(...collectVocabularyFromSnapshot(state.snapshot.value));
    }
  } catch {
    // Vocabulary is an optimisation. If the shell is not loaded yet, dictation
    // still works — it is just less accurate on project-specific words.
  }

  return normalize([...STATIC_VOCABULARY, ...normalize(dynamic).slice(0, MAX_DYNAMIC_TERMS)]);
}
