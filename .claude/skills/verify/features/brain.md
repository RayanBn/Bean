# Brain

When the gate says yes, Bean shows that it is thinking in the notch, captures the screen (without its own window), and sends the capture with the trigger to Muse Spark through the Meta Model API. Muse Spark answers by calling one tool: `propose_command` (see [actions](./actions.md)), `show_message` (the notch expands with one or two sentences and "Got it"), or `stay_quiet` (the notch goes back to rest). The message closes by itself after 30 s. Every answer is logged to `brain.jsonl`. This is the first step where data leaves the Mac, and only after the gate's yes.

## Sub-features

- `brain-thinking`: right after a gate yes, the notch shows the 300×44 thinking bar.
- `brain-capture`: the request includes a screenshot of the main display (`sawScreen:true`).
- `brain-answer`: a useful answer expands the notch to 520×170 with the message and "Got it".
- `brain-quiet`: Muse Spark can call `stay_quiet`, and the notch goes back to rest without a message.
- `brain-dismiss`: "Got it" returns the notch to rest on the first click without taking focus, and the message also closes by itself after 30 s.
- `brain-log`: each answer is one `brain.jsonl` line with `gateScore`, `sawScreen`, `tool`, `message`, `command`, `latencyMs`, `model`, the token counts, and `failure` when something broke.

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
- **Thinking.** About 12 s later, `bean window` prints `300 44`, and `bean shot thinking` shows "Bean" and a spinner.
- **Answer.** About 5 s after that, `bean window` prints `520 170`, and `bean shot answer` shows a message that names the missing module and `pip install requests` (or `pip3`), with "Got it". The last `brain.jsonl` line has `sawScreen:true`, `tool` `show_message` or `propose_command`, the same message, and no `failure`. If it proposed a command, do not press "Run it" here: `pip install` would change the machine. Use the [actions](./actions.md) scenario for that.
- **Dismiss.** Run `bean frontmost`, then click "Got it". Read its position from `answer.png` (bottom right of the panel) and run `swift .claude/skills/verify/bin/click.swift <x> <y>`. `bean window` goes back to the rest frame, and `bean frontmost` prints the same bundle id as before.
- **Quiet.** `bean terminal-error "TypeError: Cannot read properties of undefined (reading map)"` gives no code context. Muse Spark may call `stay_quiet`, and then the notch goes back to rest. Both outcomes are valid. Report which one happened.
- **Proof.** `thinking.png`, `answer.png`, the `brain.jsonl` line, and the frames.

## Gotchas

- Every run calls the real Muse Spark API and costs about 2,000 to 2,600 tokens (around $0.005). Do not loop it.
- The answer depends on what the screenshot shows. If another window covers the terminal, the answer gets vaguer or the brain stays quiet.
- Only one question runs at a time. A gate yes that comes while Bean is thinking is ignored, and `brain.jsonl` has no line for it.
- `BEAN_BRAIN_EFFORT` (default `low`) and `BEAN_BRAIN_MODEL` (default `muse-spark-1.3`) change the call. `none` is not a valid effort.
- The look of the thinking and message states belongs to the notch feature, so screenshots change when the notch UX changes. Assert the frames and the log, not the pixels.
