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
| Gate model | Muse Spark in the cloud by default (`reasoning_effort: minimal`, text only, never a screenshot). Llama 3.2 3B on the Mac (llama.cpp, `~/Models/llama32`) as an option in Settings | Rayan's call on Oct 26: no local model by default, so install needs no download. Cloud eval 20/20, about 1 s. Local eval 19/20, 0.08 s, 2 GB, and nothing leaves the Mac until the gate says yes. Muse Glimmer (30B) was measured on D1: 6–22 s per decision, 17 GB of RAM. |
| Gate target | JEV (`typesafe-ai/jev`), with Rayan's own access | Built for calibrated yes/no scores, which a chat model like Llama 3.2 3B does not give. Llama stays for now; the gate moves to a JEV-like model later, or sooner if Llama's score is too unstable. |
| Brain | Muse Spark, Meta Model API over HTTP | The Meta model at the center of the project. |
| Brain boundary | The brain sits behind one interface, separate from the notch app | Lets the brain change later without touching the app. |
| Distribution | Run locally for the demo | The Accessibility API is not allowed in the App Store sandbox. Developer ID and notarization come after the hackathon. |
| Repo | Private on RayanBn during the event, public before submission | |

## Way of working

Copied from how Lauren Tan (poteto) runs her agents: the code is split by feature, a project `verify` skill drives the real app, and a feature map says how to prove each feature.

Code by feature:

- `Bean/Features/<Feature>/` holds everything one feature needs: views, logic, data types. `Bean/App/` only creates the features and wires them together.
- Today: `Notch`, `Signals`, `Triggers`, `Gate`, `Brain`, `Actions`, `Shell`, `Repo`, `Browser`, `Presence`, `Settings`. `Bean/Shared/BeanSettings.swift` holds the settings, and environment variables override them for verification. `Bean/Shared/` holds `JSONLog`, `Accessibility` (AX reads) and `TerminalText` (prompt, command output and error parsing).
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
- **Oct 26 (data sources, part 1):** `Features/Shell`: a consent card in the notch, then one line in `~/.zshrc` sources `bean.zsh`, which logs every command with exit code, cwd and terminal to `shell.jsonl` (secret-looking commands skipped). New triggers `commandFailed` and `repeatedFailure` (3 fails of the same command in 10 min). The gate lets `repeatedFailure` through by rule: Llama scored it ~0.4, and a prompt tweak broke other cases. Gate eval 19/20 (only miss: the web search). `Features/Repo`: branch, changed files, last commit and `gh` CI for the cwd or the frontmost VS Code folder, added to the Muse Spark request. Proven live (runs `d7-shell`, `d7-shell-2`): consent, install, three failures from a VS Code-tagged zsh, rule yes, brain called with the repo summary (it stayed quiet: nothing was on screen). Browser and meeting signals are with the session `bean-browser-presence`.
- **Install with no manual steps:** only the macOS grants (Accessibility, Screen Recording) need the user, guided from Settings. The local model is now optional, so nothing to download by default. Muse Spark access: each user pastes their own Meta API key in Settings (Rayan's call, Oct 26). It is stored in the Keychain, and Bean asks for it in the notch at launch when it is missing.
- **Oct 26 (settings, cloud gate):** the gate runs on Muse Spark in the cloud by default (`minimal` effort, JSON `{stepIn, confidence}`, text only): eval 20/20, median 0.85 s. The local Llama is a Settings option, started only when needed (eval 19/20). New Settings window, opened from Bean at rest → "Settings": gate model, threshold per provider, stuck and away delays, quiet during calls, Muse Spark model and effort, key status, zsh hook on and off, browser tab reading, Accessibility and Screen Recording state with buttons to open their panes. Browser and Presence (from the session `bean-browser-presence`) are wired: snapshots carry the active tab and the call state, a web search that matches the stuck error fires `searchingError` (always steps in), an app switch never steps in (no model call), and nothing steps in during a call. Proven live: run `s-settings` (window opens from the notch), run `s-search-3` (DuckDuckGo search of the stuck error in Safari → rule yes → Muse Spark proposes touch + rebuild). A first try was falsely "in a meeting" because the other session was testing the camera at the same time.
- **Oct 26 (API key):** each user pastes their own Meta API key in Settings. Key order: `MODEL_API_KEY` env, then the repo `.env` (dev), then the Keychain (`dev.rayanbn.Bean.meta-api`). Without a key, the notch asks for one at launch with "Open Settings". Proven live (run `s-key`, test Keychain service): prompt, paste, save to the Keychain, the next call used it (401 with the fake key), test item deleted.
- **Oct 26 (providers):** the AI provider is a setting: Meta (Muse Spark, default, keeps the hackathon's Meta requirement), OpenRouter (gateway to many models), or any OpenAI-compatible endpoint (OpenAI, Groq, Ollama, LM Studio, llama-server). One key per provider, in the Keychain. `MuseSpark` became `ModelClient`. Eval: Meta 20/20; OpenAI-compatible against a local Llama 3B server 15/20 (the path works, the 3B model is the limit). OpenRouter is not tested (no key). The settings UI moves to a menu bar icon with a sober popover, delegated to the session `bean-notch-ux`.
- **Ideas for later:** user connectors (for example MCP servers: GitHub, Linear, Slack) that Bean can read from and act through.
- **Oct 26 (context, Rayan's direction):** after using Bean, Rayan found it not useful: it only reacted to terminal errors, while his day is spent driving Claude Code agents and the browser (real logs: `shell.jsonl` and `brain.jsonl` empty). His direction: Bean listens to events, knows the whole Mac, has its own hidden terminal to do what it needs, looks at the screen and takes control only when needed. Connectors (Linear) come later. Built `Features/Context`: a picture of the Mac rebuilt every 20 s (windows on all Spaces with their AX text, every tab of Arc/Chrome/Brave/Safari, Claude Code agent sessions with state, seen or not, question and last recap, recent zsh commands, files changed in 30 min, dev servers). Proven by `bean probe-context` on the real Mac: 11 apps, 60 tabs, 17 agent sessions in 2.2 s. The brain is now an agent loop: it gets the picture, investigates with `run_shell` in a hidden terminal (outward or destructive commands refused) and `look_at_screen` on demand (no screenshot by default), then answers `offer_action` (one click runs a command hidden), `propose_plan`, `show_message` or `stay_quiet`, in one sentence that gives the conclusion. New triggers `agentWaiting` (an agent asks or finished, unseen for 2 min, fired at a pause, once per turn) and `backFromBreak` (back after 10 min away with agents waiting); they think silently and speak at most 3 times an hour. Gate eval 25/25 with 5 new cases. Live proof (run `agent-live-1`): a waiting agent session → gate yes 0.94 → Muse Spark ran `git status`/`git log`/`gh pr view` hidden → "Branche useful prête… La merger dans main ?" with "Ouvrir session" in 7 s → the click ran it (`ran`, 0.1 s), focus unchanged. Not done: Rayan's real-use session, opening one exact agent session (the button opens the Claude app), Linear connector, text of Electron windows.
- **Oct 26 (events, not polling):** Rayan rejected the 20 s rebuild of the context: Bean must listen to events. Every poll is gone: an Accessibility observer on the frontmost app (focus, title, terminal value changes), `NSWorkspace` app switches, one `IdleClock` with one-shot timers that re-arm on input (idle, back from a break, waiting for a pause), one-shot timers for `stuckOnError` and `agentWaiting`, FSEvents for agent sessions and changed files, a file event for `shell.jsonl`. The full picture of the Mac (windows, tabs, ports) is built only when the brain asks. Proven live: terminal error caught 1 s after it appeared, stuck at exactly 10 s (run `events-1`); a waiting agent fixture → gate 0.96 → "Agent notch : designs A (liste) et B (cartes) prêts, dis-lui lequel garder." [Open session] in 5.2 s, 2 rounds; idle and back-from-break fired (run `events-2`). A real session fired during run `events-3`: SP-950 finished unseen 4 min earlier → gate 0.94 → Bean checked the PR with `gh` → "SP-950 : CI verte, PR #1606 MERGEABLE, prête à merger." [Merge PR], declined in the test. Gate eval 25/25. Bean still uses about 5 % CPU at rest: the samples show it is the notch's SwiftUI `TimelineView` animation, not the signals.
- **Oct 26 (inventory, the foundation):** Rayan's direction: build the base first, an inventory of everything on the Mac fed by events, wired to nothing. Researched before building (open-source code of AltTab, yabai, AeroSpace, screenpipe, ActivityWatch, atuin; Apple SDK headers and forums; 2024-2026 papers; HN and GitHub threads). `Features/Inventory`: apps by KVO on `runningApplications`; one AXObserver per app on a dedicated AX thread (1 s global, 0.25 s per call timeouts) for window open, close, focus, title, minimize, tab; WindowServer list for every window on every Space with Space ids (`CGSCopySpacesForWindows`); the focused window's text with batched AX reads capped at 250 ms / 5,000 nodes, web content first, `AXManualAccessibility` once a minute for Electron and Chromium except VS Code, Cursor and Claude; tabs by AppleScript after a browser window event; non-app processes with arguments from a PID diff every 3 s plus kqueue exit events (no push API exists without root and an Endpoint Security entitlement); system notifications for network, power, displays, lock, sleep, Spaces and volumes. Every change goes to `inventory.jsonl`; the full snapshot is built only on demand (`SIGUSR1` or the probe). Measured on the real Mac (runs `inv-2` to `inv-4`): 11 Dock apps with windows on 6 Spaces, 77 to 89 tracked processes with their command lines (Gradle, Expo, Android emulator, MCP servers), 60 tabs, Arc page text 7,485 characters in 252 ms, TextEdit open/type/close/quit all logged, about 0.5 % CPU at rest (was 8 % when the snapshot was rebuilt every 5 s). Not done: SkyLight WindowServer events (private, changed in Sequoia), text of windows on other Spaces.
- **Oct 26 (signing):** Bean is signed with a local self-signed identity, "Bean Local Signing" (in Rayan's login keychain, private key usable by `codesign` only). Its designated requirement is now `identifier "dev.rayanbn.Bean" and certificate leaf = H"7f42…"` instead of an ad-hoc hash, so macOS keeps the Accessibility and Screen Recording grants across rebuilds. Bean asks for Screen Recording at launch, and logs a `launched` signal with both grant states. Proven: after Rayan granted both once, a rebuild with a code change launched through `run.sh` logged `accessibility: true, screenRecording: true`. A Developer ID and notarization are still needed to distribute.
