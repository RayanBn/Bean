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
- Today: `Notch`, `Signals`, `Triggers`, `Gate`, `Brain`, `Actions`. `Bean/Shared/` holds `JSONLog`, `Accessibility` (AX reads) and `TerminalText` (prompt, command output and error parsing).
- Other features drive the notch only through `NotchController.think()`, `show(NotchMessage)` and `rest()`. `Bean/Shared/JSONLog.swift` is the JSONL writer both logs use.
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
- **Oct 26 (D3 started early, done):** `Features/Gate`. Bean starts its own `llama-server` with Llama 3.2 3B and stops it on quit. Each trigger gets a score, P(yes) / (P(yes) + P(no)) read from the first token's logprobs, and a decision at threshold 0.65, logged to `gate.jsonl` with latency and model. Labeled cases in `evals/gate-cases.jsonl` (16), run with `bean gate-eval`: 15/16 at 0.65, median 74 ms. Live proof: run `d3-live` (app change and fresh error say no, stuck says yes). Weak spots: a web search for the error scores ~0, and failure words without a failure (`0 failed`) score ~0.6, just under the threshold. JEV should fix both.
- **Oct 26 (D4 started early, done):** `Features/Brain`. On a gate yes: the notch shows thinking, Bean captures the main display without its own window (ScreenCaptureKit), and sends it with the trigger to `muse-spark-1.3` (`reasoning_effort: low`, JSON schema `{stayQuiet, message}`). A useful answer opens the notch with the message and "Got it", which closes on the first click and after 30 s by itself. Logged to `brain.jsonl`. Key read from the repo `.env` through `BeanSourceRoot` in Info.plist. Proven live (run `d4-live-2`): a stuck `ModuleNotFoundError` gave "Run `pip3 install requests` and rebuild." in 4.9 s, about 2,600 tokens. With a context-free TypeError (run `d4-live`) Muse Spark chose to stay quiet. The trigger description moved to `Trigger.summary`, shared by the gate and the brain; gate eval unchanged (15/16).
- **Notch UX** is delegated to the session `bean-notch-ux`: 2–3 concepts for Rayan to pick, then the chosen one built in `Features/Notch`, keeping the notch API above.
- **Oct 26 (D5 started early, done):** `Features/Actions`. Muse Spark now answers with one tool: `propose_command`, `show_message` or `stay_quiet`. A proposed command shows in the notch with "Not now" / "Run it". On "Run it", Bean brings the terminal of the error to the front and types the command with Return (CGEvent), visibly. Nothing runs without the click. A denylist (`sudo`, `rm -rf`, force push, `git reset --hard`, disk tools, multi-line) turns a proposal into text only. Logged to `actions.jsonl`. Fixed: a stuck trigger now names the terminal of the error, not the app in front. Proven live: run `d5-run-from-away` (user in another app, "Run it" brings Terminal back and runs `touch cache-refreshed`, the file appears), run `d5-decline-3` (nothing typed). The verify helper got a shared notch lock, since the notch UX session runs Bean too.
- **Oct 26 (D6 started early, done):** Bean takes control over several steps. Muse Spark answers with `propose_plan` (1–4 commands, ending with the one that proves the fix). On confirm, the notch lists the steps, the screen edge glows, the terminal is highlighted, and Bean types each command, waits for its prompt to return, and reads its output. A failing step stops the plan, and Bean asks Muse Spark once more with the new output. The new notch states from the UX session are wired: notice → thinking text → message → acting with steps → "Fixed", and the quiet counter (gate no on non-app-switch triggers, and `stay_quiet`). Proven live (run `d6-live`): the fake build failed on `cache-refreshed`, Bean ran touch + rebuild, the rebuild failed on `lockfile.ok`, Bean asked again (3.6 s), ran touch + rebuild, the build passed, and the notch said "Fixed".
- **Notch UX:** concept B (morphing island, screen-edge glow when Bean takes control) landed in `78df9ed`. The UX session now proposes a mascot to Rayan.
- **Data sources:** inventory done (19 sources). Top 5 to add, in order: zsh `preexec`/`precmd` hooks (commands, exit codes and cwd from every terminal, VS Code too), git + `gh` on the active repo, browser AX in Arc (URL, tabs, page text; fixes the gate's web-search miss), window titles → repo path with Vision OCR as fallback, mic/camera in use (stay quiet in meetings). Do not toggle `AXManualAccessibility` on VS Code.
