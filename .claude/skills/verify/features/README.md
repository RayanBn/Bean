# Bean verification map

This directory is the maintained source for verifying what a Bean user sees and gets. Read this index before driving Bean, then use the matching feature file as the recipe.

## Baseline preconditions

- `bean build` succeeded on the commit under test.
- No Bean process runs except the one `bean launch` started for this run.
- `BEAN_RUN_ID` is set for the whole run, so evidence lands in `artifacts/verify/$BEAN_RUN_ID/`.
- `bean doctor` prints `OK`.
- Verification runs use gate port 8189 (`BEAN_GATE_PORT`), so they never talk to the user's own Bean on 8089.
- The built-in display is on. The pill mode for screens without a notch needs an external display and is not driven yet.

## Driving conventions

- Start every recipe from a fresh `bean launch`. Bean starts at rest.
- Locate Bean's window by PID with `bean window`. Never click fixed coordinates.
- Drive the user path only: clicks through `bean tap`, app switches through `bean activate`, terminal errors through `bean terminal-error`.
- Return the panel to rest at the end of a recipe.

## Proof and skip reporting

- Capture the action and the resulting state: a screenshot before and after, and the frame that `bean tap` prints.
- Quote the signal log lines for any logging behavior.
- After a click on Bean, `bean frontmost` must show the same app as before: Bean never steals focus.
- Record the feature ID and the entry point next to every artifact.
- Report an unreachable path with the command you tried and the precondition that was not met.
- Never report a skipped entry point as verified through another path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the behavior the user sees. Then come exactly four H2 sections, in this order:

1. `Sub-features`: short IDs, one line each.
2. `How to get to it (user POV)`: every user entry point.
3. `Driving it with bean`: starts with `Preconditions:`, then labeled bullets that pair each user action with an exact command and an observable result.
4. `Gotchas`: traps that waste or invalidate a run.

Keep implementation details out of the map.

## Features

- [Notch panel](./notch.md) covers the panel at rest, expanding and collapsing on a click, and focus.
- [Signal log](./signals.md) covers app switches, window changes and idle periods written to the log.
- [Gate](./gate.md) covers the local gate model: its server, one scored decision per trigger, and the labeled eval.
- [Triggers](./triggers.md) covers app changes, terminal errors, being stuck on an error, and idle, written to the trigger log.
