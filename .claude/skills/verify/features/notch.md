# Notch panel

At rest, Bean is a black shape that extends the notch by a small ear on each side, with Bean's two green eyes side by side in the right ear. A click on it expands a panel from the notch with Bean's message. A second click returns it to rest. Neither click takes focus from the app the user is in.

## Sub-features

Every state is one black island that morphs with a spring inside a fixed 640×340 transparent window that never resizes. The window ignores the mouse except over the island, so clicks around it reach the apps below. `bean window` prints the island's frame (the AX element `bean-island`), not the window's, so `tap`, `click` and `shot` follow the island. Compact states sit in the notch row and use its ears; expanded states drop below it.

- `notch-eyes`: Bean's mascot is a pair of green eyes, side by side just right of the camera, in the notch row of every state, like a small creature peeking out of the right ear. Rest: calm, they blink every few seconds and follow the cursor. Notice: wide open. Thinking: they look up and drift. Message: open, following the cursor. Acting: narrowed, scanning left and right; once a step fails, worried slanted eyes that tremble until the next state (proof: run `mascot-worried-3`, `failed.png`). Done: happy arcs. A quiet tick closes them for a moment.
- `notch-quiet`: `stayedQuiet()` ticks a gray number in the left ear at rest.
- `notch-notice`: `notice(word)` widens the ears: the word in the left ear, the eyes wide open in the right ear.
- `notch-thinking`: `think(text)` drops a 380-wide bar with three green dots and shimmering text.
- `notch-message-choices`: `show(NotchMessage)` with choices shows capsule buttons, primary green. One click on a button acts, with no focus change.
- `notch-acting`: `act(steps:)`, `advance()`, `step(_:_:)` show a step list: done steps checked, the running one spins, a `n/N` counter.
- `notch-done`: `done(text)` is a compact bar: green check and text in the left ear, happy eyes in the right ear.
- `notch-pill`: on a screen without a notch the same states run as a rounded pill at the top center, 6 points below the top.

- `notch-rest`: the panel sits centered on the notch, as tall as the notch, slightly wider, with the two green eyes in the right ear.
- `notch-expand`: a click expands it to a 548-wide panel (520 plus the two 14-point top flares) showing "Bean" and the message.
- `notch-collapse`: a second click returns it to the rest frame.
- `notch-no-focus`: the frontmost app is the same before and after each click.

## How to get to it (user POV)

- Look at the notch: Bean is there as soon as it launches.
- Click Bean's shape in the notch.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Bean was just launched and is at rest.

- **Rest.** Run `bean window` and `bean shot rest`. The frame is centered on the screen's mid-x, with `Y=0` and the notch height (32 on a 14" MacBook Pro), 241 wide on that screen, and the screenshot shows a green eye on each side of the notch.
- **Focus before.** Run `bean frontmost` and keep the bundle id.
- **Expand.** Click Bean. Run `bean tap`, then `bean shot expanded`. The printed frame is 548 wide, its height fits the text, still centered with `Y=0`, and the screenshot shows "Bean" and the message under the notch.
- **No focus taken.** Run `bean frontmost`. It prints the same bundle id as before.
- **Collapse.** Click again. Run `bean tap`, then `bean shot collapsed`. The frame equals the rest frame.
- **Proof.** `rest.png`, `expanded.png` and `collapsed.png` in `artifacts/verify/$BEAN_RUN_ID/`, the three frames, and the two identical `frontmost` lines.

## States only the Brain and Actions reach

`notice`, `thinking` with text, the message with choices, `acting`, the screen glow, the target halo, `done` and the quiet counter have no user entry point yet. Drive them through the real Brain flow once it calls them. For a click on a choice, use `bean press "<label>"`.

- `notch-takeover`: `act(steps:)` lights a glow around the whole screen that grows out of the notch both ways (a click-through overlay window under the island, drawn and animated by Core Animation off the main thread: Bean stays near 11% CPU while it glows, against 98% with the old SwiftUI blur). `highlight(rect)` frames a target with a pulsing green halo; the rect is in global top-left screen coordinates, as Accessibility gives them. Any other state retracts the glow into the notch.

Proof made with a temporary hook, since removed: run `eyes-right` (eyes in the right ear: `rest`, `quiet`, `notice`, `acting-settled`, `done`), run `eyes-burst` (30 frames of notice → acting, no jump once settled), run `mascot-eyes-2`, and earlier runs `notch-foundation` (each state, first-click buttons, no focus change), `notch-foundation-pill` (pill mode) and `notch-glow` (`glow-in.png`, `acting-full.png` with halo, `done-retract.png` with the glow gone).

## Gotchas

- With a dark menu bar, the rest shape blends into it. Only the two green eyes show. That is the intended look, not a failure.
- `bean tap` clicks 24 points left of the island's right edge, in the notch row, which lands inside the island in every state. `click.swift` and `press.swift` move the cursor there first and wait 80 ms, since the window only takes the mouse once the cursor is over the island.
- `bean tap` needs the launching process (terminal or Claude) to be allowed in Privacy & Security → Accessibility to post clicks. Without it, the frame never changes.
- The island springs for about 0.4 s. Read it after `bean tap` returns, not during the click.
- For smoothness, record a video (`screencapture -v -V 4 -R <rect> file.mov`) and look at frames with ffmpeg: run `smooth-fixed` (`morph2.mov`, `glow.mov`).
- A full-screen app hides the menu bar, but Bean stays above it. That is expected.
