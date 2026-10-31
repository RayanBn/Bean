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
- **Sweep.** `Bean --probe-hands sweep '<bundle#title>' <args.json>` runs the tool with those arguments. With `write`, each line of `source` starts with its row number and a tab, so a wrong offset cannot shift the answers.

Check the result in the app itself (a value read by script, a server log), never only by the run's own summary: a field can show a text the app has not committed.

## Gotchas

- Windows on another Space return no Accessibility windows. Bring the app forward once under the notch lock.
- `open -g` on a full-screen Space puts the window on another Space, so it is unreachable.
- Never set `AXFocused` to true: it brings the app forward. In a web view a press moves the focus inside the page, and the value then lands in the right field. A web field that cannot be pressed is refused.
- A pop-up menu raises its window and holds the keyboard for about 0.5 s until it closes. `WindowControls` then gives the front back. Any other control that brings its app forward gives it back after 0.15 s.
- `BEAN_HANDS_TYPE=1` on `--probe-hands run` types real keys while the first app has the focus, under the notch lock. `typed sent=` must match what arrives in that app, and `background focus_moves=` lists every move.
- A native name field may only commit on Return, and Numbers ignores the loss of focus. The plan adds a `return` step. Return is offered only on search fields and one-line native fields, because Return can send a web form or a message.
- `--probe-hands-guard` checks the press guard against a table of labels, with no model call. A checkbox, radio button or pop-up holds a choice, so only money words stop it. A button is judged on its words, so a button named "Share usage data" stays refused.
- Numbers: the sheet tab name has no control once a table is selected, so an agent uses `app_script` there.
