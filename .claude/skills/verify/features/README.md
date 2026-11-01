# Bean verification map

This directory is the maintained source for verifying what a Bean user sees and gets. Read this index before driving Bean, then use the matching feature file as the recipe.

## Baseline preconditions

- `bean build` succeeded on the commit under test.
- No Bean process runs except the one `bean launch` started for this run.
- `BEAN_RUN_ID` is set for the whole run, so evidence lands in `artifacts/verify/$BEAN_RUN_ID/`.
- `bean doctor` prints `OK`.
- The built-in display is on. The pill mode for screens without a notch needs an external display and is not driven yet.

## Driving conventions

- Start every recipe from a fresh `bean launch`. Bean starts at rest.
- Locate Bean's window by PID with `bean window`. Never click fixed coordinates.
- Drive the user path only: clicks through `bean tap`, notch buttons through `bean press "<label>"`.
- Return the panel to rest at the end of a recipe.

## Proof and skip reporting

- Capture the action and the resulting state: a screenshot before and after, and the frame that `bean tap` prints.
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

- [Onboarding](./onboarding.md) covers the first run: the objective, the brain and key, what Bean sees, the macOS switch, the real drag, the first result, and resuming after a quit.
- [Notch panel](./notch.md) covers the panel at rest, its states, expanding and collapsing on a click, and focus.
- [Settings](./settings.md) covers the menu bar icon and its popover: pause, AI provider and key, off limits and permissions.
- [Creatures](./creatures.md) covers the agents as creatures: in the notch, the drag onto a window, the perch that follows it, and home.
- [App actions](./actions.md) covers how an agent acts in any app in the background: AppleScript, Accessibility, menus, URLs, shortcuts, and what the guard refuses.
- [Calls](./calls.md) covers an agent hearing a call on its window: detection, consent, recording state, transcript on this Mac, recap and hand-off to Bean.
- [Main scenario](./e2e.md) covers a call through to delegated work and one report, in one command, with nobody at the Mac.
- [Senses](./senses.md) covers what agents can notice: the manifest, subscriptions, the three tools and the pipe to the gate.
- [Connectors](./connectors.md) covers MCP servers found in local configs and the registry, OAuth, and their tools.
- [Control page](./control-page.md) covers the board of widgets: the headline, the bar, Add Widget, terminal, files, memory, changes, plan, history, live pictures, drag and resize.
- [Agents](./agents.md) covers creating an agent with Bean, its folder, reading the window it is plugged into, and the agent card.
