# Bean — plan

## What Bean is

Bean is the butler that lives in your Mac's notch. It is always there: it knows what you are doing, it sees your screen, it acts, and it takes control when the task needs it. Like a good butler, it is discreet. It speaks up only when it can help, and stays quiet the rest of the time.

The problem: AI assistants wait to be asked, and the ones that watch the screen capture everything without knowing when to stay quiet. An assistant that interrupts too often gets turned off within a day. Bean's edge is judgment: a fast local model decides whether to step in before anything else happens.

## Hackathon

- **Event:** Meta Global AI Developer Hackathon. Indie Developer track, solo.
- **Theme:** "Push the Frontier", software.
- **Dates:** Monday Oct 26 to Wednesday Nov 4, 2026.
- **Deadline:** Wed Nov 4, 9:00 PM ET (Thu Nov 5, 3:00 AM Paris). Submit at https://cerebralvalley.ai/e/meta-ai-developer-hackathon/hackathon/submit
- **Submission:** public repo, working demo video link (3 minutes, one of the main scoring items).

Rules that can disqualify:

- Everything presented is built between Oct 26 and Nov 4. The first commit is on Oct 26.
- The demo shows only what was built during the event. Judges must be able to tell what is new: say clearly which parts are external models and APIs.
- No code, data or assets without the rights to them.
- The project builds on Meta Model API, Muse Code or Meta's open-weights models.
- Banned generic projects include simple image analyzers. Bean must read as an agent that acts, not as a screenshot analyzer.

## Experience

- At rest, Bean lives in the notch, invisible or as a small discreet indicator, like the iPhone's Dynamic Island.
- When Bean steps in, the notch expands into a panel with Bean's message and the action it proposes.
- On a screen without a notch (an external monitor), Bean is a pill at the top center.
- Bean never steals focus. It asks before any irreversible action.

## How it works

1. **Know (local, nothing leaves the Mac):** frontmost app (`NSWorkspace`), window titles and content (Accessibility API), idle time (`CGEventSource`).
2. **Decide (local):** on each event (app or window change, an error in a terminal, stuck for N minutes), the gate model gets the signals and answers "step in or not".
3. **See:** only after a yes, Bean captures the screen (`ScreenCaptureKit`).
4. **Think:** Muse Spark gets the signals and the capture and decides what to do.
5. **Act and control:** open apps, type, click (`CGEvent`, Accessibility actions), run commands. Irreversible actions need the user's confirmation in the notch panel.

## Stack and decisions

| Decision | Choice | Why |
|---|---|---|
| App | Swift, SwiftUI + AppKit, macOS 14+ | The notch overlay (a non-activating `NSPanel` above the menu bar, sized with `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`), Accessibility, ScreenCaptureKit and CGEvent are native APIs. Low memory for an always-on app. |
| Gate model | Llama 3.2 3B Instruct Q4, local via llama.cpp (`~/Models/llama32`) | Meta open weights, 2 GB, 0.18 s per decision on the M5. Muse Glimmer (30B) was measured on D1: 6–22 s per decision because its reasoning cannot be turned off, and 17 GB of RAM. Keeps the privacy promise: nothing leaves the Mac until Bean decides to step in. |
| Gate target | JEV (`typesafe-ai/jev`), with Rayan's own access | Built for calibrated yes/no scores, which a chat model like Llama 3.2 3B does not give. Llama stays for now; the gate moves to a JEV-like model later, or sooner if Llama's score is too unstable. |
| Brain | Muse Spark, Meta Model API over HTTP | The Meta model at the center of the project. |
| Brain boundary | The brain sits behind one interface, separate from the notch app | Lets the brain change later without touching the app. |
| Distribution | Run locally for the demo | The Accessibility API is not allowed in the App Store sandbox. Developer ID and notarization come after the hackathon. |
| Repo | Private on RayanBn during the event, public before submission | |

## Way of working

Copied from how Lauren Tan (poteto) runs her agents: the code is split by feature, a project `verify` skill drives the real app, and a feature map says how to prove each feature.

Code by feature:

- `Bean/Features/<Feature>/` holds everything one feature needs: views, logic, data types. `Bean/App/` only creates the features and wires them together.
- Today: `Notch`, `Signals`, `Triggers`. Planned: `Gate` (D3), `Brain` (D4), `Actions` (D5–D6). `Bean/Shared/JSONLog.swift` is the JSONL writer both logs use.
- A feature uses another only through the types and methods it exposes (the gate reads `Signal`, not `SignalCollector` internals).
- One session owns one feature folder. Parallel sessions never edit the same folder. Code that two features need moves to `Bean/Shared/`, and only then.
- Each feature folder has a matching file in the verify feature map, with the same name.

Proof:

- `.claude/skills/verify/` builds, launches and drives Bean (`bin/bean`), and keeps proof in `artifacts/verify/<run>/`.
- `.claude/skills/verify/features/` holds one file per user-facing feature: sub-feature IDs, user entry points, the exact commands that drive it and the observable result, and gotchas.
- Done means a `verify` run on the feature's file passed, with its screenshots and log lines cited. A new feature or a changed behavior updates its feature file in the same commit.
- `/maintain-verification-skill` keeps the map honest when the app changes.

## Demo scenarios

1. **Stuck on an error:** the same error stays in the terminal for 3 minutes. Bean expands from the notch, explains the cause and offers the fix, then applies it on a yes.
2. **Outdated API in the open repo:** Bean spots a call to a deprecated API in the project you are editing and proposes the migration.
3. **The number:** one hour of real work, logged. "Bean stayed quiet X times and stepped in Y times, rightly."

## Day-by-day plan

| Day | Date | Goal |
|---|---|---|
| D1 | Mon Oct 26 | Xcode project, notch panel at rest, signals collected and logged. Test Glimmer locally: format, RAM, latency. Test Muse Spark access: vision, tool use. |
| D2 | Tue Oct 27 | Event triggers (app change, terminal error, idle), signal log |
| D3 | Wed Oct 28 | Gate (Glimmer or JEV), every decision logged with score and latency |
| D4 | Thu Oct 29 | Muse Spark: capture, reasoning, answer in the expanded notch |
| D5 | Fri Oct 30 | Bean acts: simple actions, confirmation for irreversible ones |
| D6 | Sat Oct 31 | Bean takes control: multi-step tasks |
| D7 | Sun Nov 1 | Demo scenarios polished |
| D8 | Mon Nov 2 | One hour of real use for the number, fixes |
| D9 | Tue Nov 3 | 3-minute video, README that shows what was built during the event |
| D10 | Wed Nov 4 | Buffer, repo public, submit |

## Risks

- Glimmer's latency and memory on this Mac are unknown. Test on D1.
- Muse Spark 1.3 capabilities (vision, tool use) are not verified. Test on D1.
- Notch size APIs need macOS 12+, and `safeAreaInsets` can read as zero on some notched Macs.

## Status

- **Oct 26:** project set up. Notch panel at rest (expands on click) and signal log (frontmost app, window title, idle) built and seen working; window titles need the Accessibility grant. Model research done:
  - Muse Glimmer is a single 30B model (Q4 GGUF 16.8 GB, ~17–20 GB RAM), reasoning cannot be turned off, ~27 tok/s on an M5 Max. Likely too slow for a gate: to measure with a small `--reasoning-budget`. Fallbacks: JEV, or Llama 3.2 3B (Meta open weights, ~2 GB).
  - Muse Spark: `https://api.meta.ai/v1`, OpenAI-compatible, model `muse-spark-1.3`, image input and tools (`tool_choice: auto` only), $1.25/$4.25 per M tokens, no hackathon credits listed. Key from dev.meta.ai/platform, needed from Rayan.
  - Credits: the hackathon gives Rayan $150 (per Rayan). Not using Glimmer is fine: the README and the video say it was measured and set aside.
  - Muse Spark tested with Rayan's key (`.env`, `MODEL_API_KEY`): text 2.3 s, screenshot + tool call 5.8 s and correct, `reasoning_effort: minimal` 1.2 s (`none` is refused).
  - Verify skill and feature map added (notch panel, signal log), proven end to end: run `d1-proof`. Code moved to `Bean/Features/` and proven again: run `features-move`.
  - Gate measured on 6 labeled cases with a JSON schema answer: Glimmer 5/6, 6–22 s; Llama 3.2 3B 5/6, 0.18 s. Gate switched to Llama 3.2 3B. Its miss was the clearest case (same terminal error for 3 min): prompt and logprob score to tune on D3.
- **Oct 26 (D2 started early, done):** `Features/Triggers` turns signals into triggers in `triggers.jsonl`: `appChanged`, `terminalError` (new error line in Terminal, iTerm2, Warp or Ghostty, read through Accessibility, with the last 20 lines), `stuckOnError` (same error after `BEAN_STUCK_SECONDS`, default 180, even if the user left the terminal), `idle` (`BEAN_IDLE_SECONDS`, default 300). Proven: runs `d2-triggers-2` (error then stuck at 12 s), `d2-idle`, `d2-regression`. Not covered: the VS Code and Claude terminals.
