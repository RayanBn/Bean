# Notch panel

At rest, Bean is a black shape that extends the notch by a small ear on each side. Bean itself is a pearl drop in the right ear, with the same eyes as its agents; its eyes and the agents' heads look toward the cursor when it is near. The left ear holds the agents' heads and a + (always shown with no agent, on hover otherwise). A click on the island at rest opens the agents page; a click on + opens the New Agent form in the page. The notch only shows status: it never talks. Clicks never take focus from the app the user is in, except the create field, which takes the keyboard while it is open and gives it back when it closes.

## Sub-features

Every state is one black island that morphs with a spring inside a fixed 640×340 transparent window that never resizes. The window ignores the mouse except over the island, so clicks around it reach the apps below. `bean window` prints the island's frame (the AX element `bean-island`), not the window's, so `tap`, `click` and `shot` follow the island. Compact states sit in the notch row and use its ears; expanded states drop below it.

- `notch-bean`: Bean is a pearl drop in the right ear of every compact state. It sleeps while Bean is paused.
- `notch-plus`: the + sits after the heads in the left ear; the island widens on hover to show it.
- `notch-hatch`: creating an agent splits a drop off Bean; it hangs under the notch while its color fills, until Muse Spark has written it, and can be dragged at once.
- `notch-status`: working drops bob gently and scan; a stuck or out-of-scope agent glows and the island is rimmed in its color. The detail is on the page.
- `notch-message-choices`: `show(NotchMessage)` with choices shows capsule buttons, primary white. One click on a button acts, with no focus change.
- `notch-pill`: on a screen without a notch the same states run as a rounded pill at the top center, 6 points below the top.

- `notch-rest`: the panel sits centered on the notch, as tall as the notch, slightly wider, with Bean in the right ear.
- `notch-collapse`: a click on a message returns it to the rest frame.
- `notch-no-focus`: the frontmost app is the same before and after each click.

## How to get to it (user POV)

- Look at the notch: Bean is there as soon as it launches.
- Click Bean's shape in the notch. Settings live in the menu bar icon: see [settings.md](./settings.md).

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Bean was just launched and is at rest.

- **Rest.** Run `bean window` and `bean shot rest`. The frame is centered on the screen's mid-x, with `Y=0` and the notch height (32 on a 14" MacBook Pro), 279 wide on that screen, and the screenshot shows Bean's pearl drop in the right ear.
- **Focus before.** Run `bean frontmost` and keep the bundle id.
- **No focus taken.** Run `bean frontmost`. It prints the same bundle id as before.
- **Collapse.** With a message showing (for example the no-key prompt at launch from a worktree build), run `bean tap`, then `bean shot collapsed`. The frame equals the rest frame.
- **Proof.** `rest.png`, `collapsed.png` in `artifacts/verify/$BEAN_RUN_ID/`, the frames, and the identical `frontmost` lines.

## Gotchas

- With a dark menu bar, the rest shape blends into it. Only Bean, the heads and the + show. That is the intended look, not a failure.
- `bean press` and `bean fill` teleport the cursor. Move it onto the island first (a mouse-moved event), or the click passes through the panel to whatever is under it; on the wallpaper, macOS then reveals the desktop.
- `bean tap` clicks 24 points left of the island's right edge, in the notch row, which lands inside the island in every state. `click.swift` and `press.swift` move the cursor there first and wait 80 ms, since the window only takes the mouse once the cursor is over the island.
- `bean tap` needs the launching process (terminal or Claude) to be allowed in Privacy & Security → Accessibility to post clicks. Without it, the frame never changes.
- The island springs for about 0.4 s. Read it after `bean tap` returns, not during the click.
- For smoothness, record a video (`screencapture -v -V 4 -R <rect> file.mov`) and look at frames with ffmpeg.
- A full-screen app hides the menu bar, but Bean stays above it. That is expected.
