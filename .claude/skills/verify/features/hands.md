# Instant hands and Sweep

`window_hands` drives a window without the mouse or keyboard, at about 0.2 s per step. `sweep` asks one question of every item in a list. Both need Strands: without it (`Strands.isOn` false) neither tool is offered and agents work as before.

## Sub-features

- `hands-plan`: Muse Spark writes the steps and all text (`InstantHands.plan`).
- `hands-pick`: code lists the legal controls, Strands picks one; below 0.6, unless the step names the control, Muse Spark picks from the top 5 (`InstantHands.act`).
- `hands-guard`: `WindowControls.refusal`, the same rule as `window_act`, removes controls before any model sees them, and forbidden ones go back to the plan.
- `hands-check`: code reads the window after each step. Muse Spark checks the end, up to 3 plans.
- `sweep`: Strands per item, under 0.7 to Muse Spark. Code adds up numbers (`SweepReport.text`).

## Driving it with bean

Preconditions: `BEAN_DATA_DIR`, `BEAN_DECIDER=strands`, `MODEL_API_KEY`, `BEAN_WINDOW_FILTER=<title>`, and the window on the current Space.

- **Runner alone.** `Bean --probe-hands run '<bundle#title>' '<goal>'` prints one line per step and `RESULT finished=... median_step=... muse=...`, and whether the mouse and front app stayed the same.
- **Through an agent.** `Bean --probe-hands agent '<bundle#title>' '<goal>'` runs the real agent. With `BEAN_DECIDER=muse` it runs the current loop, so the same goal measures both.
- **Sweep.** `Bean --probe-hands sweep '<bundle#title>' <args.json>` runs the tool with those arguments.

Check the result in the app itself (a value read by script, a server log), never only by the run's own summary: a field can show a text the app has not committed.

## Gotchas

- Windows on another Space return no Accessibility windows. Bring the app forward once under the notch lock.
- `open -g` on a full-screen Space puts the window on another Space, so it is unreachable.
- Safari applies a value set on an unfocused field to the focused one: `setValue` focuses first inside a web page.
- A native name field may only commit on Return, and Numbers ignores the loss of focus. The plan adds a `return` step. Return is offered only on search fields and one-line native fields, because Return can send a web form or a message.
- `AppGuard` also refuses harmless labels such as "Share usage data" and "By post".
- Numbers: the sheet tab name has no control once a table is selected, so an agent uses `app_script` there.
