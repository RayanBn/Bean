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
- Drive the user path only: clicks through `bean tap`, app switches through `bean activate`, terminal errors through `bean terminal-error`, notch buttons through `bean press "<label>"`.
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
- [Settings](./settings.md) covers the menu bar icon and its popover: pause, AI provider and key, gate, delays, sources and permissions.
- [Shell](./shell.md) covers the zsh hook consent, the command log, and failed and repeated-failure triggers.
- [Signal log](./signals.md) covers app switches, window changes and idle periods written to the log.
- [Actions](./actions.md) covers proposed commands: confirming, running them in the user's terminal, declining, and blocked commands.
- [Steps and recipes](./steps.md) covers typed UI steps through each app's own channels with their effect checked, and recipes Bean learns per app.
- [Connectors](./connectors.md) covers MCP servers found in local configs and the registry, their tools in the brain, and `connect`.
- [Brain](./brain.md) covers what happens after a gate yes: thinking, the hidden-terminal investigation, the screenshot on demand, the Muse Spark answer in the notch, one-click actions, and dismissing it.
- [Inventory](./inventory.md) covers the event-driven inventory of the whole Mac: apps, windows on all Spaces, focused window text, tabs, processes, system state, and its event log.
- [Context](./context.md) covers Bean's picture of the whole Mac (windows, tabs, what apps are working on through learned recipes, commands, files, servers) and the `unseenChange` and `backFromBreak` triggers.
- [Gate](./gate.md) covers the local gate model: its server, one scored decision per trigger, and the labeled eval.
- [Followup](./followup.md) covers hearing a call: detecting it, asking consent, capturing both sides, transcribing on the Mac, and handing the transcript to the brain.
- [Triggers](./triggers.md) covers app changes, terminal errors, being stuck on an error, idle, and `Events.post` for any other sense, written to the trigger log.
- [Browser page](./browser.md) covers the active tab's URL, title and search query in Arc, Safari and Chrome, and nothing on mail sites.
- [Presence](./presence.md) covers mic and camera in use and meeting apps in front.
- [Stream guard](./streamguard.md) covers noticing a screen share, hiding private things from viewers with shields, the Muse Spark review, and the model download.
- [Routines](./routines.md) covers learning a task the user repeats in any app or terminal, the repeatSeen event, the brain's offer, and the replay of what is left, including loops over similar items.
