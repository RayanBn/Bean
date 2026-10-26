# Gate

Every trigger goes to the gate. By default it is Muse Spark in the cloud (`reasoning_effort: minimal`, JSON `{stepIn, confidence}`), which gets a short text description of the trigger, never a screenshot. In Settings it can be Llama 3.2 3B on this Mac instead, which Bean starts the first time it is needed. The gate returns a score between 0 and 1 for "should Bean step in now". Bean steps in when the score reaches the provider's threshold (cloud 0.5, local 0.65). Rules come first: an app switch never steps in, nothing steps in during a call, and a repeated failure or a web search for the stuck error always steps in. Every decision is written to `gate.jsonl` with its score, its latency and the model. Nothing leaves the Mac at this stage.

## Sub-features

- `gate-cloud`: with the default provider, each decision's `model` is `muse-spark-1.3 (minimal)`, and its latency is about 1 s.
- `gate-server`: with the local provider, the first decision starts `llama-server` on `BEAN_GATE_PORT` (8089 by default, 8189 in verification runs), and quitting Bean stops it.
- `gate-decision`: each trigger produces one `gate.jsonl` line with `trigger`, `score`, `stepIn`, `threshold`, `latencyMs` and `model`, or a `failure` when the model could not answer.
- `gate-judgment`: when the user is stuck, the score is high. App switches, fresh errors and idle time get low scores.
- `gate-rule`: `repeatedFailure` and `searchingError` always step in, and the decision keeps the model's score and adds the rule. `appChanged` never steps in and skips the model (`rule: appChanged`, no score). In a call (`inMeeting`) with "Stay quiet during calls" on, nothing steps in and the model is skipped (`rule: inMeeting`).
- `gate-eval`: the labeled cases in `evals/gate-cases.jsonl` score at the expected side of the threshold.

## How to get to it (user POV)

- Run Bean and work. The gate judges every trigger in the background.
- The log is `~/Library/Application Support/Bean/gate.jsonl` for the user's copy, and `artifacts/verify/$BEAN_RUN_ID/data/gate.jsonl` for a verification run.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- `~/Models/llama32/Llama-3.2-3B-Instruct-Q4_K_M.gguf` exists and `/opt/homebrew/bin/llama-server` is installed.
- Nothing else listens on port 8189.

- **Eval.** Run `bean gate-eval`. It runs the real gate on every labeled case and prints one `ok`/`MISS` line per case, then the accuracy at the current threshold, the latency, and the best threshold. Run it per provider with `BEAN_GATE_PROVIDER=cloud` or `local`. Expect 20/20 for cloud at 0.5 (median about 1 s) and at least 19/20 for local at 0.65 and a median under 200 ms. The exit code is 0 only if every case passes. The output is saved to `gate-eval.txt`.
- **Live.** Run `BEAN_STUCK_SECONDS=10 bean launch`, then `bean terminal-error "TypeError: Cannot read properties of undefined (reading map)"`, then wait 14 s and run `bean gate`. There is one decision per trigger: `appChanged` with `stepIn:false`, `terminalError` with `stepIn:false`, `stuckOnError` with the highest score of the three. Each decision has a `latencyMs` under 1000 and no `failure`.
- **Server lifecycle.** While Bean runs, `pgrep -fl "llama-server.*8189"` shows the gate server. After `bean cleanup`, it shows nothing, and `bean cleanup` prints no warning about the gate port.
- **Proof.** `gate-eval.txt` and the `gate.jsonl` lines in `artifacts/verify/$BEAN_RUN_ID/`.

## Gotchas

- The score depends on how long the error has been on screen. With `BEAN_STUCK_SECONDS=10`, the gate reads "12 seconds" and scores the stuck trigger around the threshold. With the real 180 s, it reads "3 minutes" and scores higher. Judge the threshold with `bean gate-eval`, not with the short live run.
- Known miss: switching to a browser to search the error scores near 0. The gate does not yet link the browser title to the earlier error.
- Known near misses: output that mentions failure words without failing (`0 failed`, `error reporter initialized`) scores 0.59–0.60, just under the threshold.
- The first decision after launch includes the model warm-up and can take a few hundred milliseconds.
- If port 8189 is busy, `llama-server` fails, and every decision has `failure` set. Check `artifacts/verify/$BEAN_RUN_ID/data/gate-server.log`.
- A Bean killed with `kill -9` leaves its `llama-server` running. `bean cleanup` warns when the gate port is still in use.
