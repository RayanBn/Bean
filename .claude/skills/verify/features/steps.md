# Steps and recipes

Beyond the terminal, Bean acts in any app through typed steps (`open`, `press`, `setValue`, `typeText`, `keys`, `menu`, `script`, `shell`, `terminal`, `window`, `wait`). Each step goes through the most reliable channel the app exposes: its AppleScript dictionary (found with `sdef`), an Accessibility action only when the element advertises it, focus and a key, a click at the element's frame with the cursor put back, then Muse Spark vision (never for an irreversible step). A return code is never trusted: each step is checked by its postcondition or by a change in the window's Accessibility text, which becomes its learned postcondition. Steps Bean learns for an app are kept as recipes (`recipes.json`): act recipes (steps with `{parameters}`) and read recipes (a sandboxed program). They are learned by trying only that app's own channels and reading under `sandbox-exec`, saved only once verified, trusted after two good replays, and relearned with the lessons of a failure.

## Sub-features

- `steps-channels`: `channels.jsonl` gets one line per step with `channel`, `ok`, `effect` and `learnedPost`.
- `steps-card`: `do_steps` and `achieve` cards list their steps in the notch while they run.
- `recipes-learn`: `learning.jsonl` gets one line per attempt with rounds, calls, tokens and why it failed.
- `recipes-replay`: a saved recipe replays through the channels and its state moves `candidate` → `confirmed` → `trusted`.

## How to get to it (user POV)

- Accept a `do_steps` or `achieve` card: Bean takes control, the notch lists the steps and checks them off.
- The logs are `channels.jsonl`, `learning.jsonl` and `recipes.json` in Bean's data folder.

## Driving it with bean

Preconditions:

- Hold the notch lock (a `bean launch` of this run) before any step that brings an app to the front: other runs click on the screen.

- **Channels.** Write steps as JSON and run `BEAN_DATA_DIR=<run>/data bean probe-steps <file> [--background]`. Run `core-steps`: TextEdit `script` make document (ok), `setValue` on `AXTextArea` (channel `axValue`, effect `AXTextArea bean-probe written by Bean`, learned `textAppears`), `window` frame (bounds `200, 200, 840, 620`), `menu` Format › Make Rich Text (ok), Safari `open` a local page and `press` `domId: ready` (channel `axAction`, title `READY-…`).
- **Windows.** A `window` step finds the window by title on any Space (WindowServer list, then the AX element by its remote token), moves it to a Space, sets its frame, or enters full screen and waits for its own Space. Run `core-window`: TextEdit framed (bounds `120, 120, 820, 540`), full screen in 2.3 s, back in 0.7 s.
- **UI listing.** `bean probe-ui <bundle-id>` prints what `read_ui` gives the brain.
- **Learn.** `BEAN_DATA_DIR=<run>/data build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean --probe-learn <bundle-id> read|act "<goal>" [hint]` learns and saves a recipe (read recipes: see [context](./context.md)). Run `core-act`: TextEdit "open a document of the user in this app" learned in 8 s, 3 rounds (`app_facts`, `app_dictionary`, `read_files` in one round, then `try_steps`), one `open` step with `{document_path}`.
- **Replay.** `--probe-replay <recipe-id> name=value…` replays it through the channels. Run `core-act`: another document opened, state `trusted` after 2 successes.
- **Visible terminal.** A `terminal` step (what `open_terminal` runs) opens a new terminal window in the given folder. Run `core-act`: `claude --version; codex --version` printed `2.1.296 (Claude Code)` and `codex-cli 0.162.1`.

## Gotchas

- Menu titles follow the app's state (Make Rich Text vs Make Plain Text): read the menu first.
- Arc's web buttons answer `AXPress` with a false success; the AX diff catches it and the next channel runs.
- A learning or a takeover step moves the mouse and the focus: never run it while another run holds the notch lock.
