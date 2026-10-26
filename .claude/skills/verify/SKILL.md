---
name: verify
description: Build, launch and drive Bean, the macOS notch assistant in this repo, the way a user does, and capture proof (screenshots of the notch, the signal log, the frontmost app). Use before calling any Bean change done, to reproduce a Bean bug, or when asked to run, test or screenshot Bean.
---

# Verify Bean

Bean is a menu-bar-less macOS app (`LSUIElement`). Its only visible surface is a borderless, non-activating panel over the notch (a pill at the top center on screens without a notch). Its other surface is the signal log, a JSONL file. Everything goes through one helper:

```bash
.claude/skills/verify/bin/bean <command>
```

Run it from the repo root. Set `BEAN_RUN_ID=<slug>` for the whole run so evidence lands in `artifacts/verify/<slug>/` (gitignored). Without it, the run is `local`.

## Launch

1. `bean build` generates the Xcode project with XcodeGen and builds Debug into `build/`. Ready when it prints `built .../Bean.app`.
2. `bean launch` starts the built binary directly (not through `open`) with `BEAN_DATA_DIR=artifacts/verify/<run>/data`, so the run writes its own logs and never touches `~/Library/Application Support/Bean`. Bean starts its own gate server, `llama-server` on port 8189 for verification runs. It records the PID in `artifacts/verify/<run>/bean.pid` and waits for Bean's window. Ready when it prints `ready pid=... window=X Y W H LAYER`.

Only one Bean can own the notch. `bean launch` takes a shared lock (`~/Library/Caches/bean-verify.lock`) and waits up to 10 min while another run holds it, and `bean cleanup` releases it. `bean launch` refuses with exit code 2 when a Bean process it did not start is running, which is usually the user's own copy. Ask the user before quitting it. Never quit it yourself.

Teardown is `bean cleanup`.

## Doctor

`bean doctor` is read-only. It checks that the recorded PID is alive and runs this checkout's build, prints the build time, the window frame and layer (25 is `.statusBar`), the number of logged signals, and how many carry a window title. Run it first, and again whenever anything looks off.

## Drive

| Command | What the user does | What it does |
|---|---|---|
| `bean tap` | Clicks the notch | Posts a real click on the right ear of Bean's window (located by PID through `CGWindowList`, never by fixed coordinates), puts the cursor back, prints the new frame |
| `bean terminal-build` | Runs a failing build | Writes a fake `build.sh` in the run directory that fails first on a missing `cache-refreshed`, then on a missing `lockfile.ok`, and opens Terminal running it, then an interactive shell there |
| `bean shell-run "<cmd>" [times] [term]` | Runs a command in a new terminal | Runs it in a real interactive zsh in a PTY that loads the run's `.zshrc`, so the zsh hook logs it as coming from `term` (default `vscode`) |
| `bean press "<label>"` | Clicks a notch button | Finds the button by its accessibility label in Bean's window, posts a real click on its center, prints the new frame |
| `bean activate <bundle-id>` | Switches app | `open -b <bundle-id>`, then prints the last 3 signals |
| `bean frontmost` | | Prints the frontmost app's bundle id, to prove Bean took no focus |
| `bean window` | | Prints Bean's window frame |
| `bean terminal-error "<line>" ["<line>"...]` | Hits an error in Terminal | Opens a Terminal window titled `bean-verify` in the run directory, prints a fake build command and the lines, then leaves an interactive shell there. `bean cleanup` ends it |
| `bean signals` | | Prints this run's signal log |
| `bean triggers` | | Prints this run's trigger log |
| `bean gate` | | Prints this run's gate decisions |
| `bean brain` | | Prints this run's Muse Spark answers |
| `bean actions` | | Prints this run's proposed, run, declined and blocked commands |
| `bean gate-eval [cases.jsonl]` | | Runs the real gate on the labeled cases (`evals/gate-cases.jsonl` by default) and prints the score of each, the accuracy and the best threshold |

The feature recipes live in [features/README.md](features/README.md). Read the index, then the feature file you are proving.

## Evidence

- `bean shot <name>` writes `artifacts/verify/<run>/<name>.png`, a capture of the notch area wide enough to show the menu bar around it.
- The signal and trigger logs are `artifacts/verify/<run>/data/signals.jsonl` and `triggers.jsonl`. Quote the lines that prove the change.
- Thresholds are environment variables read at launch: `BEAN_STUCK_SECONDS`, `BEAN_IDLE_SECONDS`, `BEAN_GATE_THRESHOLD`. Shorten them on the `bean launch` line, never in code.
- Proof standards:
  - Drive the real path: a real click on the panel, a real app switch. Never toggle state through code or a debug hook.
  - Capture the action and the resulting state: a screenshot before and after, and the frame from `bean tap`.
  - Check the side effects as well as the screen. A signal must be in the log, and the frontmost app must be unchanged after a click on Bean.
  - Calls to Muse Spark and the local gate are real. Never mock them in a proof. If a model is unreachable, report the feature as blocked.

## Cleanup

`bean cleanup` kills only the PID this run recorded, and ends the Terminal script that `bean terminal-error` started. It keeps every artifact, the signal log included, in `artifacts/verify/<run>/`. Run it after every run, also after a failed one.

## Helpers

- `bin/bean` is the CLI above.
- `bin/window.swift <pid>` prints `X Y W H LAYER` for that PID's on-screen window.
- `bin/press.swift <pid> <label>` clicks the button with that accessibility label.
- `bin/click.swift <x> <y>` posts a left click at screen points, then puts the cursor back.

The Swift files run through the `swift` interpreter, so each call takes about a second.
