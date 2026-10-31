# Notch panel

At rest, Bean is a black shape that extends the notch by a small ear on each side. The left ear holds a + and the agents at home. The right ear holds Bean, one small dot per agent on a window, an amber dot and rim while something waits, and a green check when a report is unread. Hovering or clicking opens one panel under the notch: the list of agents, each with its window, or the waiting question first. The page opens only from "Open Bean" in that panel, or a click on a row. Nothing here takes focus, except the + field, which takes the keyboard while it is open and gives it back when it closes.

## Sub-features

Every state is one black island that morphs with a spring inside a fixed 640×340 transparent window that never resizes. The window ignores the mouse except over the island, so clicks around it reach the apps below. `bean window` prints the island's frame (the AX element `bean-island`), not the window's, so `tap`, `click` and `shot` follow the island. Compact states sit in the notch row and use its ears; expanded states drop below it.

- `notch-bean`: Bean is a pearl drop in the right ear of every compact state. It sleeps while Bean is paused.
- `notch-plus`: the + is always in the left ear. It opens one field; Return makes the agent, Esc closes.
- `notch-hatch`: creating an agent splits a drop off Bean; it hangs under the notch until Muse Spark has written it. The panel then shows it large and wiggling, with "Drag <name> onto any window".
- `notch-status`: a dot per placed agent, breathing while it works. Header in the list: "1 needs you · 2 working".
- `notch-card`: a question or offer: what, what Bean saw, buttons, and one quiet action (Hide, Other where the options need it, or Details on truncated answers). A short choice that would send words is hidden unless the agent's `Perimeter` allows it. One at a time. It opens at a pause (10 s idle, or an app switch after 30 s on one app), never while the person types (`NotchPacer`), holds 14 s, then folds to the dot and comes back once on return. A call opens at once. It never takes the keyboard.
- `notch-line`: the one report: one line, then a check. Clicking expands what was done, with Undo where it exists, and Reopen for a finished session, on that click only.
- `notch-return`: after 10 minutes away or a lock, one line: "While you were away: 2 done, 1 question."
- `notch-pill`: on a screen without a notch the same states run as a rounded pill at the top center, 6 points below the top.

- `notch-rest`: the panel sits centered on the notch, as tall as the notch, slightly wider, with Bean in the right ear.
- `notch-no-focus`: the frontmost app is the same before and after each click.

## How to get to it (user POV)

- Look at the notch: Bean is there as soon as it launches.
- Hover or click Bean's shape: the panel opens. Settings live in the menu bar icon: see [settings.md](./settings.md).

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Bean was just launched and is at rest.

- **Rest.** Run `bean window` and `bean shot rest`. The frame is centered on the screen's mid-x, with `Y=0` and the notch height (32 on a 14" MacBook Pro), 279 wide on that screen, and the screenshot shows Bean's pearl drop in the right ear.
- **Focus before.** Run `bean frontmost` and keep the bundle id.
- **No focus taken.** Run `bean frontmost`. It prints the same bundle id as before.
- **Collapse.** With a message showing (for example the no-key prompt at launch from a worktree build), run `bean tap`, then `bean shot collapsed`. The frame equals the rest frame.
- **Proof.** `rest.png`, `collapsed.png` in `artifacts/verify/$BEAN_RUN_ID/`, the frames, and the identical `frontmost` lines.

- **Every surface at real size, no input.** `BEAN_DATA_DIR=<dir> Bean --probe-notch-surfaces <file.png>` renders each state with long text. Put `{"language":"French","languageChosen":true}` in `<dir>/user.json` and a `strings-french.json` next to it for French.
- **Fake offers and reports.** Launch with `BEAN_NOTCH_FAKE_FILE=<file>` and append JSON lines: `{"offer":{"result":"...","saw":"...","answers":["A","B"],"now":false}}` or `{"report":{"line":"...","link":"...","items":["..."],"undoable":true,"reopen":["Reopen"]}}`. `BEAN_AWAY_SECONDS=25` shortens the return line. Pair with `bin/fake-model.py` through `BEAN_BASE_URL` for creation with no paid call.

## Gotchas

- `bean window` and `bean shot` read a stale height for an open panel. Capture Bean's panel with `screencapture -l <window number>` instead.
- Have a harmless app frontmost, such as TextEdit, before any real key: a key that misses the field lands there.

- With a dark menu bar, the rest shape blends into it. Only Bean, the heads and the + show. That is the intended look, not a failure.
- `bean press` and `bean fill` teleport the cursor. Move it onto the island first (a mouse-moved event), or the click passes through the panel to whatever is under it; on the wallpaper, macOS then reveals the desktop.
- `bean tap` clicks 24 points left of the island's right edge, in the notch row, which lands inside the island in every state. `click.swift` and `press.swift` move the cursor there first and wait 80 ms, since the window only takes the mouse once the cursor is over the island.
- `bean tap` needs the launching process (terminal or Claude) to be allowed in Privacy & Security → Accessibility to post clicks. Without it, the frame never changes.
- The island springs for about 0.4 s. Read it after `bean tap` returns, not during the click.
- For smoothness, record a video (`screencapture -v -V 4 -R <rect> file.mov`) and look at frames with ffmpeg.
- A full-screen app hides the menu bar, but Bean stays above it. That is expected.
