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
an agent instantly, this makes the harness unusable. Fixing that *interaction*
is the job.

## Where the code lives

- `apps/vision/Sources` — this app. Small, ~300 lines.
- `apps/swift-ios/Core` — the transport. **Referenced by path, not copied.**
- `apps/swift-ios/App/Cloud` — T3 Connect. Also referenced.

`project.yml` (xcodegen) wires those three together. Do not copy files out of
`apps/swift-ios`; the SwiftUI client is still churning upstream and referencing
keeps one source of truth. Every file in `Core` imports only Foundation and
Security, which is why it ports to visionOS unmodified.

## Building

**This repo checkout cannot build the app** unless it is on macOS with Xcode 26
and the visionOS SDK. A Linux box can write and reason about the Swift, but
cannot compile it, run tests, or deploy to the headset.

Write code as if it must compile, because someone else will find out that it
doesn't. Be conservative: check API signatures in `apps/swift-ios/Core` before
using them rather than assuming shapes.

On a Mac the loop is:

```sh
cd apps/vision
xcodegen generate
xcodebuild -project T3Vision.xcodeproj -scheme T3Vision -configuration Release \
  -destination 'generic/platform=visionOS' -derivedDataPath build \
  DEVELOPMENT_TEAM=SZP9K9CJAX -allowProvisioningUpdates build
```

## Current state

Works: pairing to a server by URL, connecting, a live thread list that updates
from `shellEvents`.

Not built yet: thread detail, composer, dictation, interrupt/steer, task
creation, project views, spatial windows. The app is a proof that the transport
works — nothing more.

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

Open question worth answering with a real test: when interrupt is dispatched
mid-tool-call, does the provider abort promptly or only after the tool returns?
That decides whether steering feels instant or merely eventual.

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

On visionOS the natural gesture is gaze plus pinch-and-hold, and the composer
belongs in an ornament rather than the content plane.

## Conventions

Conventional commit titles. Match surrounding code style. Check signatures in
`Core` rather than guessing — most of the time lost so far has been wrong
assumptions about APIs that were one `grep` away.
