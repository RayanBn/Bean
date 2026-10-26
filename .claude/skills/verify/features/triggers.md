# Triggers

Bean watches the signals and marks the moments when it might be worth stepping in: the user switches app, an error shows up in the terminal, the same error is still there minutes later, or the user stops touching the Mac for a while. Each moment becomes one JSON line in `triggers.jsonl`, with the context the gate will need. A trigger is a candidate, not an interruption: the gate decides later.

## Sub-features

- `trigger-app`: switching apps writes `appChanged`.
- `trigger-error`: a new error line in the focused terminal writes `terminalError` with `errorLine` and `terminalTail` (the last 20 lines).
- `trigger-stuck`: the same error line still being the latest error after `BEAN_STUCK_SECONDS` (default 180) writes `stuckOnError` once, with `errorSeconds`. It fires even if the user went to another app, for example to search the error.
- `trigger-idle`: no input for `BEAN_IDLE_SECONDS` (default 300) writes `idle` once per idle period.

## How to get to it (user POV)

- Work in Terminal, iTerm2, Warp or Ghostty and hit an error.
- Switch apps.
- Step away from the Mac.
- The log is `~/Library/Application Support/Bean/triggers.jsonl` for the user's copy, and `artifacts/verify/$BEAN_RUN_ID/data/triggers.jsonl` for a verification run.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Launch with short thresholds: `BEAN_STUCK_SECONDS=10 bean launch` for the error recipes, `BEAN_IDLE_SECONDS=5 bean launch` for idle.
- The launching process has Accessibility, so Bean can read the terminal text. `bean doctor` must show signals with a window title.

- **Error.** Run `bean terminal-error "TypeError: Cannot read properties of undefined (reading map)"`. It opens a Terminal window titled `bean-verify` that prints the line and waits, and it prints `frontmost=com.apple.Terminal`. Within 2 s, `bean triggers` shows `appChanged` to Terminal, then `terminalError` whose `errorLine` is exactly the TypeError line. The prompt line that ran the script must not be the `errorLine`.
- **Stuck.** Wait 12 s and run `bean triggers`. There is one `stuckOnError` with the same `errorLine`, `errorSeconds` ≥ 10, and a `terminalTail` that ends with the TypeError line. `bean shot terminal` captures the moment.
- **App switch.** Run `bean activate com.apple.finder`. `bean triggers` ends with `appChanged` and `"bundleId":"com.apple.finder"`.
- **Idle.** In an idle run, launch, then do not touch the Mac for 20 s. `bean triggers` holds exactly one `idle` line with `idleSeconds` ≥ 5.
- **Proof.** Quote the trigger lines in the report. The full logs and the screenshot stay in `artifacts/verify/$BEAN_RUN_ID/`. `bean cleanup` stops Bean and ends the Terminal script, and Terminal closes the window.

## Gotchas

- `stuckOnError` fires only once per distinct error line. A new error line restarts the clock. A terminal with no error line in its last 30 lines clears it.
- Only Terminal, iTerm2, Warp and Ghostty are read. The VS Code terminal and the terminal panel in Claude are not, so errors there produce no trigger yet.
- Lines that look like a shell prompt (`user@host … % `, or starting with `$ `) are skipped, so typing `grep error` does not count as an error. A tool output that only mentions the word, like `0 errors`, does not match. `failed` and `fatal` do, wherever they appear.
- The idle recipe needs the user's hands off the keyboard and mouse. If the user is working, ask first, or skip `trigger-idle` and say so.
- The error line passes through `echo '…'` in the script, so do not put a single quote in it.
- Thresholds come from the environment of the process `bean launch` starts. Set them on the `bean launch` line or export them for the run.
