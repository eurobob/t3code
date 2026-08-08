# T3 Vision — visionOS client

## What this actually is

A native visionOS T3 Code client. The point is **not** "T3 Code, but in space".
The point is that this is the one surface we control end to end, so it is where
a better interaction model gets built. T3 is the harness underneath.

Priorities, in order:

1. **Fast dictation.** Speak, it lands in the composer. This is the primary goal.
2. **Interrupt and steer.** Stop a running agent dead, and have new speech
   redirect the current turn instead of queueing behind it.
3. **Task management.** Create a task, reorder, view per project, start a task
   on a project.
4. Per-thread spatial windows. Genuinely nice, explicitly **not** the motivation.

The motivating complaint: on the iPad app, agents on long-running goals cannot
be steered or stopped. Messages sent while a turn is running are queued, not
delivered. The stop button is unreliable. Coming from a terminal where ESC halts
an agent instantly, this makes the harness unusable. Fixing that _interaction_
is the job.

## Where the code lives

- `apps/vision/Sources` — this app. Small, ~300 lines.
- `apps/swift-ios/Core` — the transport. **Referenced by path, not copied.**
- `apps/swift-ios/App/Cloud` — T3 Connect. Also referenced.

`project.yml` (xcodegen) wires those three together. Do not copy files out of
`apps/swift-ios`; the SwiftUI client is still churning upstream and referencing
keeps one source of truth. Every file in `Core` imports only Foundation and
Security, which is why it ports to visionOS unmodified.

## Branch workflow

The canonical integration branch for this client is `visionos` on the
`eurobob/t3code` fork. Start feature branches from the latest `origin/visionos`,
then merge completed work back into `visionos` and push it to that fork before
handoff unless the user explicitly asks to keep the work separate. Do not leave
finished Vision work only on a ticket-specific branch, and do not use upstream
`main` as the Vision integration target. Fetch immediately before integration
so concurrent Vision work is preserved rather than replaced.

## Building

**This repo checkout cannot build the app** unless it is on macOS with Xcode 27
and the visionOS SDK. A Linux box can write and reason about the Swift, but
cannot compile it, run tests, or deploy to the headset.

Write code as if it must compile, because someone else will find out that it
doesn't. Be conservative: check API signatures in `apps/swift-ios/Core` before
using them rather than assuming shapes.

From this box (Linux) you do not build at all — you publish, and the Mac builds:

```sh
./apps/vision/publish.sh            # build + install + launch on the headset
./apps/vision/publish.sh --logs     # …and send back what the app then logged
```

That script is the whole interface. It pushes HEAD to the branch the deploy
wrapper's submodule tracks, moves the wrapper's submodule pointer to your commit,
and hands off to `mac-verify`, which queues the job for the Mac. The Mac runs
xcodegen and builds — `mesa-deploy` opts into that for any repo shipping
`project.yml` and no `.xcodeproj`. A warm deploy is ~20s.

Do not try to reproduce those steps by hand. The step that gets missed is the
submodule pointer: pushing your branch alone leaves the wrapper pointing at the
previous commit, so the Mac cheerfully builds and installs stale code and the
deploy looks like it did nothing.

Uncommitted work cannot reach the Mac — it fetches from GitHub, not from this
disk. `publish.sh` refuses to run on a dirty tree for that reason.

On a Mac the loop is:

```sh
cd apps/vision
xcodegen generate
xcodebuild -project T3Vision.xcodeproj -scheme T3Vision -configuration Release \
  -destination 'generic/platform=visionOS' -derivedDataPath build \
  DEVELOPMENT_TEAM=SZP9K9CJAX -allowProvisioningUpdates build
```

## Current state

Implemented: pairing to a server by URL with launch-time restoration, a compact
task sidebar from `shellEvents`,
live thread detail from `threadEvents`, sending turns, explicit interrupt,
client-side steering, tap-to-record dictation, project and task creation, task
organization, and one data-driven spatial window per thread.

The task sidebar is flat by default, can optionally group by project, and keeps
project names subordinate as row pretitles or inert section headers. Completed
tasks always move into a dedicated section at the bottom, including when the
remaining tasks are grouped by project. New-task creation stays in the detail
pane and carries an exact project preselection.
Provider-advertised model options such as reasoning effort are sent through the
real `ModelSelection` option surface. The task composer is a layout-reserved
system-material voice dock: dictation is primary, manual text is opt-in, and it
never overlays the transcript. Recording continues after one tap and stops on
the next; Send can also finalize and submit an active recording. Finalized
dictation remains editable and can be cleared before send, using a
hardware-keyboard-only editor that does not summon the software keyboard.
The microphone is an unlabeled circular target with neutral, hover, and recording
colors. Selecting another task assigns the detail view that thread's identity so
SwiftUI cannot retain the previous thread model. Auto-scroll targets a spacer
after the final message to preserve breathing room above the voice dock.
Connection failures preserve the saved environment and Keychain credential;
the failure screen identifies the saved host and retries it directly instead
of forcing another pairing exchange.

Sending is optimistic: once accepted locally, the draft clears and its editor
collapses before dispatch completes; a failed dispatch restores the draft and
reopens the appropriate editor. The transcript merges messages with compact
tool, approval, and error activities and keeps a static ellipsis working row
visible from local send through provider start. Tool start/completion pairs are
deduplicated. Sidebar working, needs-you, error, updated, ready, and completed
states use one consistent pill language.
The locally persisted Updated state compares the latest terminal turn state
with what was last viewed, and clears while that task is open. Sidebar rows use
one custom selection background instead of stacking List selection and
NavigationLink focus chrome. The microphone uses the native circular lift hover
effect, and Send is a larger blue capsule.
Consecutive tool activity is collated into a compact summary such as
`Ran 5 commands · Changed 2 files`; expanding the batch restores the individual
activity rows and their own projected detail. Messages, errors, and approvals
break batches so important state remains prominent.
Voice-dock height changes scroll the transcript bottom into view so dictation
growth moves the latest bubbles above the controls; the scroll waits one layout
yield so it uses the new viewport. Successful sends do not show a redundant
confirmation. Stop is present only while the live thread reports a running turn,
and it and dictation Cancel are solid red/white buttons. Activity rows with
server-projected detail can expand to reveal it.
Live transcript following now yields as soon as the user manually scrolls and
resumes when they explicitly select the `Latest` control, manually return to the
bottom, or open another task. The control is driven by a geometry-derived bottom
visibility Boolean, so it appears only while the transcript is actually away
from the bottom; content and voice-dock growth do not expose it during follow.
Programmatic following no longer animates across long conversations, avoiding
the apparent high-speed scroll caused by new events fighting manual movement.

Every task shows one T3-owned Deploy action in the header; repositories do not
configure it and do not need a deploy entry in `t3.json`. The action runs from
`thread.worktreePath` (falling back to the project root), commits all current
worktree changes as a deployment checkpoint when necessary, pushes that exact
branch, and asks the Mac bridge to deploy it with runtime logging. Successful
output stays out of the way. A failed deployment exposes its bounded terminal
output from a compact header error control instead of presenting a modal sheet.
The terminal subscription is established before the command is written, so
immediate guard failures are not lost.

Task detail opens to the full Conversation. A global Summary control opens a
concise AI brief as a trailing third panel and keeps that choice while switching
tasks. Opening the panel requests a wider visionOS window so the task sidebar,
conversation, and summary retain readable widths. The brief puts unresolved
decisions first, then shows "What you asked", "What was done", and latest
checkpoint file changes. Generation runs on the T3 server through its configured
text-generation model (including Claude Sonnet when selected), and the Vision
client caches the result per environment/task revision. It refreshes after the
task changes, waits for active turns to settle, and offers manual regeneration.
Exact unresolved approval/input state remains deterministic so an AI summary
cannot hide a required response.

Sending while a turn is starting or running always steers: interrupt, observe
the old turn become terminal on the thread stream (normally `interrupted`, or
another terminal state if completion wins the race), then send the redirect as
the next turn. The interrupt control is never gated on cached session status
and shows the raw session/turn states. Dictation uses finalized phrases for the
draft and volatile phrases only for the HUD; cancel preserves edits that do not
exactly match the dictated suffix. Task ordering is local to each paired Vision
client because the server has no thread-order command.

The client now targets visionOS 27 and requires Xcode 27 so its ScreenCaptureKit
shared-content picker compiles directly, without a visionOS 26 fallback. The
earlier visionOS 26 implementation passed a device build and was installed and
launched on a paired Apple Vision Pro through the deploy bridge on 2026-08-07,
most recently at product commit `ab7f87a7`.
It still needs a hands-on interaction pass, especially for the Speech framework
capture path, tap target, pairing restoration, and multi-window
restoration.

A restored direct environment returning HTTP 502 is not an authentication
failure. The pairing and Keychain credential are intact; 502/503/504 mean the
saved reverse proxy is answering but cannot reach its T3 backend. On the current
host, verify the live port and repair Tailscale Serve with root privileges rather
than pairing again.

T3 Connect sign-in is wired but **does not work in this build**. Clerk rejects
the redirect: `t3code-swiftui://clerk-callback` is not in the authorised
redirect URIs for the instance our publishable key points at. Direct pairing is
the working path. Do not spend time on this; it is gated on a Clerk dashboard
change we do not control.

## The API you need

`T3Client` is an actor in `Core/T3Client.swift`. Relevant surface:

```swift
func connect() async
func shellSnapshot(timeoutInterval: TimeInterval? = nil) async throws -> OrchestrationShellSnapshot
func shellEvents(after: Int? = nil) async -> AsyncThrowingStream<ShellStreamItem, Error>
func threadSnapshot(id: String) async throws -> OrchestrationThreadDetailSnapshot
func threadEvents(threadID: String, after: Int? = nil) async -> AsyncThrowingStream<ThreadStreamItem, Error>
func generateTaskSummary(threadID: String) async throws -> GeneratedTaskSummary

func sendTurn(...) async throws -> DispatchResult
func interrupt(threadID: String, turnID: String? = nil) async throws -> DispatchResult
func createThread(...) / createThreadAndSend(...)
func respondToApproval(...) / respondToUserInput(...)
func pin(threadID:pinned:) / archive(threadID:archived:) / settle(threadID:settled:)
```

Models are in `Core/Models.swift`. `OrchestrationThread` carries `messages:
[OrchestrationMessage]`; a message has `role`, `text`, `streaming`, `turnId`.
`OrchestrationThreadShell` carries `hasPendingApprovals`, `latestTurn`, `branch`.

## Steering: the design worth building

There is no "steer" primitive on the server. There is `thread.turn.interrupt`,
which the decider turns into `thread.turn-interrupt-requested`, which
`ProviderCommandReactor` forwards to the adapter as `turn/interrupt`.

A steer is composable from what exists, entirely client-side:

1. Dispatch `interrupt(threadID:turnID:)`.
2. Wait for the turn to reach `interrupted` on the thread stream.
3. Send the new message as the next turn.

That yields ESC-then-type semantics without server changes. Note the iPad app
gates its stop button on `session.status == "running" || "starting"` — check the
real status values in `Core`, and do not silently no-op when the guard fails.
A stop that does nothing and says nothing is the current bug.

Source trace: T3 dispatches interruption immediately and does not deliberately
wait for a tool to return. Codex calls app-server `turn/interrupt`; Claude's SDK
interrupt explicitly yields `aborted_tools` mid-tool; OpenCode awaits
`session.abort`; Cursor and Grok send ACP `session/cancel` and release the local
prompt immediately. Actual wall-clock cancellation remains provider/tool
dependent, so a timed mid-tool integration test is still required.

## Dictation

An iPad implementation already exists on branch
`t3code/build-visionos-dictation-app` in `apps/mobile/modules/t3-dictation`.
Read it before designing this one. The important parts:

- `SpeechAnalyzer` + `SpeechTranscriber` with `.volatileResults`, iOS/visionOS 26+.
- Volatile results go to a HUD; **finalized** results commit into the draft as
  you speak. That split is what makes it feel real-time without the text churning.
- `AnalysisContext.contextualStrings` seeded from the live shell snapshot —
  project names, thread titles, branch names. This is the difference between
  usable and unusable for code vocabulary.
- Cancel rolls back only if the draft still ends with exactly what was appended,
  so a mid-dictation edit is never eaten.

On visionOS dictation is tap once to start and tap again to stop; do not make the
user hold a pinch for the whole utterance. The voice dock must occupy reserved
layout space so transcript content never competes with it.

## Conventions

Conventional commit titles. Match surrounding code style. Check signatures in
`Core` rather than guessing — most of the time lost so far has been wrong
assumptions about APIs that were one `grep` away.
