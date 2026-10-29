# Stream guard

When the user shares, streams or records the screen with any app, Bean notices within a few frames and hides what is private on screen from the viewers, while the user keeps seeing everything. Bean finds private things on its own in any app: an on-device model reads the text of the visible windows (Accessibility, or on-screen text recognition when an app exposes no text) and marks secrets, account numbers, phone numbers, emails, addresses, people and the like. Each one gets a shield that viewers see as a dark "hidden by Bean" box. Muse Spark then looks only at what kind of thing each shield covers, never at the text, and removes the shields that hide nothing harmful. When the share ends, every shield goes away. The model download is offered once and named: `openai/privacy-filter`, 0.9 GB, not a Meta model.

## Sub-features

- `sg-detect`: a share starting or ending is logged as `share-started` / `share-ended` in `streamguard.jsonl`.
- `sg-prearm`: before any share, the front app's private things are already found and their shields prepared (`prearmed`).
- `sg-shield`: during a share, every visible window is scanned and shields cover each private span (`shielded`, with counts per kind).
- `sg-viewer`: the viewer of the share cannot read the hidden values; the rest of the window stays readable.
- `sg-review`: Muse Spark releases shields over harmless things (`reviewed`, `released`), from metadata only.
- `sg-download`: without the model, the notch offers the download, names the model and its size.
- `sg-announce`: at the start of a share the notch says how many things are hidden and of what kind.
- `sg-new-window`: a window that opens or comes to the front during a share is covered whole before its first frame, then shielded precisely after the next scan (`window-created`).
- `sg-recorder`: a real Apple recorder (`screencapture -v`) records the shields: only the very first frame of a share can show a value.

## How to get to it (user POV)

- Start a screen share, a stream or a recording in any app (Zoom, Meet, OBS, QuickTime). Nothing to click in Bean.
- First launch without the model: the notch asks to download it.

## Driving it with bean

Preconditions:

- `bean build` succeeded. The model is installed in `~/Library/Application Support/Bean/models/privacy-filter` (or `BEAN_MODELS_DIR`).
- Never start a real share of the user's screen. `bean share-sim` captures only the windows of the fake window and of Bean, in memory, and saves its last frame.
- Write a fake text file with fake private values in the run directory, for example an API key, a phone number, an IBAN and two harmless lines.

- **Prearm.** `bean launch`, then `bean fake-window "$RUN/notes.txt"`. Within 5 s `bean streamguard` shows `prearmed` with the kinds found, then `reviewed`.
- **Share and viewer.** `bean share-sim shared`. Expect `share-started` then `shielded` in `bean streamguard`. The share-sim output lists what the viewer can read in the first and last frames: the harmless lines are readable, each private value is replaced by `hidden by Bean`. Proof image: `$RUN/shared.png`.
- **End.** After share-sim stops, `share-ended` is logged and the shields are gone.
- **Real recorder.** With the fake window up, `screencapture -x -v -V 5 -R200,200,820,300 "$RUN/recording.mov"`. Extract frames with `ffmpeg` and check the key area: frame 0 may show the value, every later frame shows the shield.
- **New window during a share.** Open a blank fake window, start `screencapture -v` over its area, then open the fake window with values on top of it. In the recording the values never appear: the area goes from blank to shield. `bean streamguard` shows `window-created`.
- **Review.** `reviewed` lines show how many shields Muse Spark released and of which kinds. The request holds no screen text.
- **Editor drawn as text (VS Code).** Open a fake file with the real VS Code (`code -n "$RUN/vscode" "$RUN/vscode/staging.env"`), then run `swift share-sim.swift` over its window frame with VS Code's pid and Bean's pid. The viewer reads `hidden by Bean` in place of each value. Close the window with `bean close-windows com.microsoft.VSCode staging.env`.
- **Covered window.** Open a blank fake window on top of the shielded one during `screencapture -v`: after the brief whole-window cover, no shield stays above the blank window.
- **No flicker.** Repeated `shielded` lines show `refilled: 0` when nothing moved.
- **Announce.** During `bean share-sim`, `bean shot announce` shows the notch message with the count.

## Gotchas

- Any screen capture counts as a share, the user's own screen recorder included: keep it off during a run.
- `bean share-sim` must get the fake window's pid from `fake-window.log`. Without it, it captures nothing.
- The first frame of a share may still show a value that was not prepared before the share (for example a window that was behind). Fake windows opened 8 s before the share are prepared.
- The user sees the real text under a shield: no capture can show it, since the shield's top layer is excluded from every capture by design. Check by eye.
- Windows on other Spaces are not scanned until they are on screen.
