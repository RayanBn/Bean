# Settings

A click on Bean at rest shows "Bean is here…" with a "Settings" button, which opens the Bean Settings window. It has four sections:

- **When to step in**: the gate model (Cloud: Muse Spark, the default, or On this Mac: Llama 3.2 3B), its threshold, the stuck and away delays, and staying quiet during calls.
- **Thinking**: the Muse Spark model and its reasoning effort, and whether the Meta Model API key was found.
- **What Bean can see**: the zsh hook (turn it on or off) and reading the active browser tab.
- **macOS permissions**: Accessibility and Screen Recording, each with an "Open" button to the right System Settings pane when it is missing.

Changes apply right away, without a restart, and are stored in Bean's user defaults.

## Sub-features

- `settings-open`: Bean at rest → click → "Settings" opens the window and brings Bean to the front.
- `settings-gate`: switching the gate model changes the `model` of the next `gate.jsonl` decisions. The local model starts `llama-server` only when it is first needed.
- `settings-delays`: the threshold, stuck and away values change the next decisions and triggers.
- `settings-shell`: "Turn off" removes Bean's two lines from `.zshrc`, and "Turn on" adds them back.
- `settings-permissions`: the two rows show the live state every 2 s.

## How to get to it (user POV)

- Click Bean in the notch at rest, then "Settings".

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).

- **Open.** Run `bean launch`, `bean tap`, `bean shot rest-menu` (the message with "Settings"), then `bean press "Settings"`. A window titled "Bean Settings" appears: check it with `swift -e` over `CGWindowListCopyWindowInfo` for the owner `Bean`, or take `screencapture -x -R <its bounds>`. The notch goes back to rest.
- **Gate model.** The eval switches the gate per run: `BEAN_GATE_PROVIDER=cloud bean gate-eval` and `BEAN_GATE_PROVIDER=local bean gate-eval`. The decisions' `model` is `muse-spark-1.3 (minimal)` or `Llama-3.2-3B-Instruct-Q4_K_M`.
- **Proof.** `rest-menu.png`, `settings.png`, the window bounds.

## Gotchas

- Environment variables win over the window (`BEAN_GATE_PROVIDER`, `BEAN_GATE_THRESHOLD`, `BEAN_STUCK_SECONDS`, `BEAN_IDLE_SECONDS`, `BEAN_BRAIN_MODEL`, `BEAN_BRAIN_EFFORT`). In a verification run, the window can show 180 s while the run uses `BEAN_STUCK_SECONDS=10`.
- Verification runs share Bean's user defaults with the user's copy. Never change a setting in the window during a verification run: the change sticks for the user too.
- Each gate provider keeps its own threshold (cloud 0.5, local 0.65 by default), because their scores are not on the same scale.
- A Bean launched by `bean launch` inherits the permissions of the launching process, so both permission rows show "Allowed" there even if `Bean.app` itself has none.
