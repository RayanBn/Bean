# Brain

When the gate says yes, Bean sends the event and its picture of the whole Mac (see [context](./context.md)) to Muse Spark through the Meta Model API. Muse Spark investigates first, for up to 6 rounds, and may call several tools in one round (reads run in parallel). Tools come from a registry: `run_shell` (hidden `zsh -lc`, 15 s, outward or destructive commands refused), `look_at_screen`, `read_ui`, `app_dictionary`, `recall`, `find_connectors`, and the read tools of connected connectors (see [connectors](./connectors.md)). It ends with act tools, `show_message` or `stay_quiet`. An act tool never runs while it thinks: each one becomes a card in the notch with the message, "Not now" and its button, up to 3 in a row, and runs with exactly the shown arguments on the click. Built-in acts: `run_command` (hidden), `open_terminal` (a long-running command in a new terminal window the user watches, such as another AI agent installed on the Mac), `run_in_terminal` (typed in the event's terminal, see [actions](./actions.md)), `do_steps` and `achieve` (UI steps and recipes, see [actions](./actions.md)), `connect` and connector writes. Events with a `notice` show it and "Looking into it" while Bean thinks; events without one think silently and speak at most `BEAN_PROACTIVE_PER_HOUR` (default 3) times an hour. A card closes by itself after 30 s. Every answer is logged to `brain.jsonl`. This is the first step where data leaves the Mac, and only after the gate's yes.

## Sub-features

- `brain-notice`: right after a gate yes, the notch shows a short notice ("Stuck?", "Error", "Still there?") for under a second.
- `brain-thinking`: then it shows the thinking state, "Looking into it". Proactive triggers skip the notice and the thinking state.
- `brain-investigate`: commands Muse Spark ran in the hidden terminal are logged in `investigation` with their exit code and output, and `rounds` counts the model calls.
- `brain-offer`: an act tool shows the message with "Not now" and its button. The click runs it, shows "Done", and logs `proposed` then `ran` (or `failed`) in `actions.jsonl` with the tool name as `appBundleId`. "Not now" logs `declined` and shows the next card.
- `brain-multi`: `toolCalls` in `brain.jsonl` lists every call in order; one round may hold several reads.
- `brain-quiet-count`: a gate no on anything but an app switch, and a `stay_quiet` answer, add one to the quiet counter at rest.
- `brain-capture`: only when Muse Spark calls `look_at_screen`, the request gets a screenshot of the main display (`sawScreen:true`).
- `brain-answer`: a useful answer expands the notch to 520×170 with the message and "Got it".
- `brain-quiet`: Muse Spark can call `stay_quiet`, and the notch goes back to rest without a message.
- `brain-dismiss`: "Got it" returns the notch to rest on the first click without taking focus, and the message also closes by itself after 30 s.
- `brain-repo`: when Bean knows the directory (from the shell hook, or the folder of the frontmost VS Code window), the request includes the repo's branch, changed files, last commit and latest `gh` CI run. Repos under `~/Documents`, `~/Desktop` and `~/Downloads` are skipped to avoid a macOS folder prompt. The summary is logged as `repo`.
- `brain-off-limits`: whatever matches the user's off-limits list (settings `offLimits`, env `BEAN_OFF_LIMITS`, case and punctuation ignored) never reaches a card: matching context lines are hidden, matching words of the event become `[off limits]`, matching tool calls are refused, matching tool output lines are hidden, matching proposals and messages are dropped, and channels refuse matching steps. `brain.jsonl` lists each drop in `dropped`.
- `brain-catalog`: the brain sees the names of every tool of each connected connector; calling one that was not offered loads it.
- `brain-log`: each answer is one `brain.jsonl` line with `gateScore`, `sawScreen`, `tool`, `message`, `command`, `proposals`, `toolCalls`, `rounds`, `latencyMs`, `model`, the token counts, and `failure` when something broke.

## How to get to it (user POV)

- Stay stuck on a terminal error. After the stuck delay, Bean thinks, then speaks in the notch.
- Read the message, then click "Got it" or let it close.
- The log is `~/Library/Application Support/Bean/brain.jsonl` for the user's copy, and `artifacts/verify/$BEAN_RUN_ID/data/brain.jsonl` for a verification run.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md), and the [gate](./gate.md) preconditions.
- `.env` at the repo root holds `MODEL_API_KEY`. Bean finds it through `BeanSourceRoot` in its Info.plist. An exported `MODEL_API_KEY` wins over the file.
- The launching process has Screen Recording permission. Without it, `sawScreen` is false and the failure says why.
- Launch with `BEAN_STUCK_SECONDS=10 BEAN_GATE_THRESHOLD=0.5 bean launch`. With the short stuck delay, the gate scores around 0.6, so the threshold has to come down for the live run.

- **Trigger.** Run `bean terminal-error "ModuleNotFoundError: No module named requests"`.
- **Thinking.** About 12 s later, `bean shot thinking` shows the notice, then "Looking at your screen".
- **Answer.** About 5 s after that, the notch is expanded and `bean shot answer` shows a message that names the missing module and `pip install requests` (or `pip3`), with "Got it". The last `brain.jsonl` line has `sawScreen:true`, `tool` `show_message` or `propose_plan`, the same message, and no `failure`. If it proposed a command, do not press "Run it" here: `pip install` would change the machine. Use the [actions](./actions.md) scenario for that.
- **Dismiss.** Run `bean frontmost`, then click "Got it". Read its position from `answer.png` (bottom right of the panel) and run `swift .claude/skills/verify/bin/click.swift <x> <y>`. `bean window` goes back to the rest frame, and `bean frontmost` prints the same bundle id as before.
- **Quiet.** `bean terminal-error "TypeError: Cannot read properties of undefined (reading map)"` gives no code context. Muse Spark may call `stay_quiet`, and then the notch goes back to rest. Both outcomes are valid. Report which one happened.
- **Offer.** `BEAN_STUCK_SECONDS=10 BEAN_GATE_THRESHOLD=0.01 bean launch`, `bean terminal-build`, `bean activate com.apple.finder`. Within 35 s `bean brain` has a proposal (`run_in_terminal` or `run_command`, both seen in run `core-brain-1`) and `investigation` shows it read `build.sh`. `bean press "<button>"` within 30 s: `bean actions` ends with `ran`, `cache-refreshed` and `lockfile.ok` exist in the run folder, `bean frontmost` is unchanged for `run_command`.
- **Proof.** `thinking.png`, `answer.png`, `offer.png`, the `brain.jsonl` line, and the frames.

## Gotchas

- Every run calls the real Muse Spark API and costs about 2,000 to 2,600 tokens (around $0.005). Do not loop it.
- The answer depends on the picture of the Mac and on what the hidden commands find, so two runs can differ. Assert the tool and the log fields, not the exact words.
- With investigation, a run costs several model calls (2 to 8) of 5,000 to 10,000 prompt tokens each.
- Only one question runs at a time. A gate yes that comes while Bean is thinking is ignored, and `brain.jsonl` has no line for it.
- `BEAN_BRAIN_EFFORT` (default `low`) and `BEAN_BRAIN_MODEL` (default `muse-spark-1.3`) change the call. `none` is not a valid effort.
- The look of the thinking and message states belongs to the notch feature, so screenshots change when the notch UX changes. Assert the frames and the log, not the pixels.
