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
| Gate model | Muse Glimmer, local | Meta's open-weights model, named in the theme. Keeps the privacy promise: nothing leaves the Mac until Bean decides to step in. |
| Gate fallback | JEV (`typesafe-ai/jev`), with Rayan's own access | Built for calibrated yes/no scores. Used only if Glimmer is too slow or too poorly calibrated on day 1. |
| Brain | Muse Spark, Meta Model API over HTTP | The Meta model at the center of the project. |
| Brain boundary | The brain sits behind one interface, separate from the notch app | Lets the brain change later without touching the app. |
| Distribution | Run locally for the demo | The Accessibility API is not allowed in the App Store sandbox. Developer ID and notarization come after the hackathon. |
| Repo | Private on RayanBn during the event, public before submission | |

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
  - Late: Glimmer and Spark not tested yet.
