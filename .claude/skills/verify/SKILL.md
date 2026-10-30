---
name: verify
description: Build, launch and drive Bean, the macOS notch app in this repo, the way a user does, and capture proof (screenshots of the notch and the popover, the frontmost app). Use before calling any Bean change done, to reproduce a Bean bug, or when asked to run, test or screenshot Bean.
---

# Verify Bean

Bean is a menu-bar-less macOS app (`LSUIElement`). Its visible surfaces are a borderless, non-activating panel over the notch (a pill at the top center on screens without a notch) and the menu bar popover. Everything goes through one helper:

```bash
.claude/skills/verify/bin/bean <command>
```

Run it from the repo root. Set `BEAN_RUN_ID=<slug>` for the whole run so evidence lands in `artifacts/verify/<slug>/` (gitignored). Without it, the run is `local`.

## Launch

1. `bean build` generates the Xcode project with XcodeGen and builds Debug into `build/`. Ready when it prints `built .../Bean.app`.
2. `bean launch` starts the built binary directly (not through `open`) with `BEAN_DATA_DIR=artifacts/verify/<run>/data`, so the run writes its own logs and never touches `~/Library/Application Support/Bean`. It records the PID in `artifacts/verify/<run>/bean.pid` and waits for Bean's window. Ready when it prints `ready pid=... window=X Y W H LAYER`.

Only one Bean can own the notch. `bean launch` takes a shared lock (`~/Library/Caches/bean-verify.lock`) and waits up to 10 min while another run holds it, and `bean cleanup` releases it. `bean launch` refuses with exit code 2 when a Bean process it did not start is running, which is usually the user's own copy. Ask the user before quitting it. Never quit it yourself.

Teardown is `bean cleanup`.

## Doctor

`bean doctor` is read-only. It checks that the recorded PID is alive and runs this checkout's build, prints the build time and the window frame and layer (27 is `.mainMenu + 3`, high enough to take clicks over the menu bar that a full-screen app reveals). Run it first, and again whenever anything looks off.

## Drive

| Command | What the user does | What it does |
|---|---|---|
| `bean tap` | Clicks the notch | Posts a real click on the right ear of Bean's window (located by PID through `CGWindowList`, never by fixed coordinates), puts the cursor back, prints the new frame |
| `bean press "<label>"` | Clicks a notch or popover button | Finds the button by its accessibility label in Bean's windows, posts a real click on its center, prints the new frame |
| `bean choose "<current>" "<item>"` | Picks from a pop-up menu | Finds the pop-up button showing `<current>` in Bean's windows, opens it and presses the menu item `<item>`, through Accessibility |
| `bean fill "<text>"` | Types in a field | Clicks the first text field in Bean's windows and types the text |
| `bean menubar [shot]` | Clicks the menu bar icon | Presses the status item through Accessibility and prints the popover bounds; with a name, saves a capture |
| `bean popover [shot]` | | Prints the popover bounds without pressing; with a name, saves a capture |
| `bean frontmost` | | Prints the frontmost app's bundle id, to prove Bean took no focus |
| `bean window` | | Prints Bean's window frame |
| `bean agent <name> [hue] [accessory]` | | Before `launch`: writes a test agent into the run's own data |
| `bean head <agent>` / `bean perch <agent>` | | Prints the agent's head frame in the notch, or its perched creature's frame |
| `bean dragout <agent> <app>\|home` | Drags an agent out of the notch | Real press and drag from the head onto the app's front window (or the notch), prints the last creature events |
| `bean regrab <agent> <app>\|home` | Drags a perched agent | Same, from the perched creature |
| `bean drag x1 y1 x2 y2 [s]` | Drags with the mouse | Posts a real press, drag and release between two screen points |
| `bean target <app>` | | Prints `number X Y W H` of the app's front window |
| `bean events` | | Prints the creature events (`lift`, `drop`, `perched`, `home`, `click`, `rebound`) |
| `bean cpu [s]` | | Average CPU of the run's Bean over `s` seconds |
| `bean agents propose\|create\|read …` | | Runs agent creation or window reading headless, in the run's own data dir, with real Muse Spark calls. See [features/agents.md](features/agents.md) |
| `bean fixture "<title>" <file> [onscreen [x y w h]]` | | Opens a window owned by the run, offscreen unless `onscreen` (at `x y w h`, top-left screen points, when given), that shows `<file>` and follows its changes, so reading never touches the user's windows. Several can run at once |

The feature recipes live in [features/README.md](features/README.md). Read the index, then the feature file you are proving.

## Evidence

- `bean shot <name>` writes `artifacts/verify/<run>/<name>.png`, a capture of the notch area wide enough to show the menu bar around it.
- Proof standards:
  - Drive the real path: a real click on the panel, a real app switch. Never toggle state through code or a debug hook.
  - Capture the action and the resulting state: a screenshot before and after, and the frame from `bean tap`.
  - Check the side effects as well as the screen. The frontmost app must be unchanged after a click on Bean.
  - Calls to Muse Spark are real. Never mock them in a proof. If a model is unreachable, report the feature as blocked.

## Cleanup

`bean cleanup` stops only the PID this run recorded (SIGTERM, then SIGKILL after 3 s). It keeps every artifact in `artifacts/verify/<run>/`. Run it after every run, also after a failed one.

## Helpers

- `bin/bean` is the CLI above.
- `bin/window.swift <pid>` prints `X Y W H LAYER` for that PID's on-screen window.
- `bin/press.swift <pid> <label>` clicks the button with that accessibility label.
- `bin/click.swift <x> <y>` posts a left click at screen points, then puts the cursor back.
- `bin/drag.swift`, `bin/find.swift` and `bin/target.swift` back `drag`, `head`/`perch`/`find` and `target`.

The Swift files run through the `swift` interpreter, so each call takes about a second.
