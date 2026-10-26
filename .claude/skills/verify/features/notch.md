# Notch panel

At rest, Bean is a black shape that extends the notch by a small ear on each side, with a green dot in the right ear. A click on it expands a panel from the notch with Bean's message. A second click returns it to rest. Neither click takes focus from the app the user is in.

## Sub-features

- `notch-rest`: the panel sits centered on the notch, as tall as the notch, slightly wider, with the green dot.
- `notch-expand`: a click expands it to the 520×170 panel showing "Bean" and the message.
- `notch-collapse`: a second click returns it to the rest frame.
- `notch-no-focus`: the frontmost app is the same before and after each click.

## How to get to it (user POV)

- Look at the notch: Bean is there as soon as it launches.
- Click Bean's shape in the notch.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Bean was just launched and is at rest.

- **Rest.** Run `bean window` and `bean shot rest`. The frame is centered on the screen's mid-x, with `Y=0` and the notch height (32 on a 14" MacBook Pro), and the screenshot shows the green dot right of the notch.
- **Focus before.** Run `bean frontmost` and keep the bundle id.
- **Expand.** Click Bean. Run `bean tap`, then `bean shot expanded`. The printed frame is `520 170`, still centered with `Y=0`, and the screenshot shows "Bean" and the message under the notch.
- **No focus taken.** Run `bean frontmost`. It prints the same bundle id as before.
- **Collapse.** Click again. Run `bean tap`, then `bean shot collapsed`. The frame equals the rest frame.
- **Proof.** `rest.png`, `expanded.png` and `collapsed.png` in `artifacts/verify/$BEAN_RUN_ID/`, the three frames, and the two identical `frontmost` lines.

## Gotchas

- With a dark menu bar, the rest shape blends into it. Only the green dot shows. That is the intended look, not a failure.
- `bean tap` needs the launching process (terminal or Claude) to be allowed in Privacy & Security → Accessibility to post clicks. Without it, the frame never changes.
- The frame animates for about 0.25 s. Read it after `bean tap` returns, not during the click.
- A full-screen app hides the menu bar, but Bean stays above it. That is expected.
