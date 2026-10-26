# Actions

When Muse Spark sees a single shell command that would fix the problem, Bean proposes it in the notch with "Run it" and "Not now". Nothing runs without that click. On "Run it", Bean brings the terminal where the error happened to the front, types the command there, and presses Return, visibly, as if the user typed it. Commands that are too dangerous (`sudo`, `rm -rf`, force pushes, `git reset --hard`, disk tools, multi-line input) are never offered to run: Bean shows them as text only. Every proposal and its outcome is logged to `actions.jsonl`.

## Sub-features

- `action-propose`: a fixable stuck error opens the notch with the message, the command, "Not now" and "Run it". `actions.jsonl` gets `proposed`.
- `action-run`: "Run it" brings the terminal of the error to the front, even if the user went to another app, types the command, presses Return. The command's effect happens, and `actions.jsonl` gets `ran`.
- `action-decline`: "Not now" closes the notch, nothing is typed, and `actions.jsonl` gets `declined`.
- `action-blocked`: a dangerous command is shown with "Got it" only, and `actions.jsonl` gets `blocked`.
- `action-failed`: if the terminal is gone or does not come to the front, nothing is typed, the notch says why, and `actions.jsonl` gets `failed`. If focus moves away while typing, Return is not pressed.

## How to get to it (user POV)

- Stay stuck on a terminal error whose fix is one command. Bean proposes it. Click "Run it" or "Not now".
- The log is `~/Library/Application Support/Bean/actions.jsonl` for the user's copy, and `artifacts/verify/$BEAN_RUN_ID/data/actions.jsonl` for a verification run.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md), and the [brain](./brain.md) preconditions.
- Launch with `BEAN_STUCK_SECONDS=10 BEAN_GATE_THRESHOLD=0.5 bean launch`.
- The scenario script leaves an interactive shell in the run directory, so a typed command really runs there and only touches `artifacts/verify/$BEAN_RUN_ID/`.

- **Propose.** Run `bean terminal-error "Error: build cache is stale (cache-refreshed marker missing)." "Build failed. To fix, run: touch cache-refreshed"`, then `bean activate com.anthropic.claudefordesktop` to leave the terminal as a user would. About 20 s later, `bean window` prints `520 170`, `bean shot proposal` shows the message with `touch cache-refreshed`, "Not now" and "Run it", and `bean actions` ends with `proposed`.
- **Run.** Run `bean frontmost` (not Terminal), then `bean press "Run it"`. Within 3 s, `bean frontmost` prints `com.apple.Terminal`, `artifacts/verify/$BEAN_RUN_ID/cache-refreshed` exists, `bean actions` ends with `ran`, and the notch is back at rest.
- **Decline.** In a fresh run, repeat Propose, then `bean press "Not now"`. The notch goes back to rest, `cache-refreshed` does not exist, and `bean actions` ends with `declined`.
- **Proof.** `proposal.png`, the `actions.jsonl` lines, the existence or absence of `cache-refreshed`, and the `frontmost` lines before and after.

## Gotchas

- Every run calls Muse Spark once (about 2,500 tokens). The command it proposes can vary. The stale-cache scenario names the fix in the error so the proposal stays `touch cache-refreshed`.
- Never use a scenario whose fix changes the machine outside the run directory (like `pip install`). The proposal would really run.
- Keep hands off the keyboard between "Run it" and the Return: typing goes to the frontmost app, and Bean aborts before Return if focus moves.
- If the user switches apps while the error is on screen, the stuck trigger still names the terminal. That is what lets "Run it" bring the right terminal back.
- `bean press` finds the button through Bean's accessibility tree by its label, then clicks its center. If the notch UX renames a button, update this file.
- The denylist lives in `TerminalCommand.blockedPattern`. It is a safety net, not the main guard: the main guard is that nothing runs without "Run it".
