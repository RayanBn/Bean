# Signal log

While it runs, Bean writes one JSON line per signal to `signals.jsonl`: the frontmost app when it changes, the focused window's title when it changes, and the start and end of idle periods. This is what the gate will read. Nothing leaves the Mac.

## Sub-features

- `signal-launch`: on launch, one `appActivated` line for the app already in front.
- `signal-app`: switching apps writes `appActivated` with the app name and bundle id.
- `signal-window`: changing the focused window (another tab or document) writes `windowChanged` with the new `windowTitle`. Needs Accessibility.
- `signal-idle`: 60 s without input writes `idleStarted`, and the next input writes `idleEnded`.

## How to get to it (user POV)

- Use the Mac normally. The log is at `~/Library/Application Support/Bean/signals.jsonl` for the user's copy, and at `artifacts/verify/$BEAN_RUN_ID/data/signals.jsonl` for a verification run.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).

- **Launch line.** Run `bean signals` right after launch. The first line is `appActivated` for the app that was in front.
- **App switch.** Run `bean activate com.apple.finder`. The last line is `"kind":"appActivated"` with `"bundleId":"com.apple.finder"`. Switch back with `bean activate <the bundle id you started from>`.
- **Window title.** Open a second Finder window, for example with `open ~/Desktop`, and wait 2 s. The last line is `windowChanged` and has a `windowTitle`. If it has none, Bean lacks Accessibility: report `signal-window` as blocked, not as passing.
- **Idle.** Leave the Mac untouched for 65 s, then run `bean signals`. There is an `idleStarted` line with `idleSeconds` ≥ 60. Then move the mouse once. Within 2 s there is an `idleEnded` line.
- **Proof.** Copy the lines that prove each sub-feature into your report. The full log stays at `artifacts/verify/$BEAN_RUN_ID/data/signals.jsonl`.

## Gotchas

- The log is written by the process that runs. A verification run writes only to its own `data/`, never to the user's log.
- Window titles come through the Accessibility API. A Bean started by `bean launch` inherits the grant of the process that launched it, not the grant of `Bean.app`.
- The idle check needs a minute with no input. Do not run it while the user is working; ask them first, or skip it and say so.
- Bean polls every 2 s, so a window change shorter than that can be missed.
