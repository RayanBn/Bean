# Onboarding

On a first launch one centered window opens. Bean asks what the person wants help with, then where its AI runs and for the key, says what it sees and lets the person close things off, asks for the macOS setting if it is off, shows the first agent's job as Bean wrote it, and waits for a real drag from the notch onto an app. The window goes away while the agent is held. After the drop one closing screen says the agent is on that app. No agent talks in this window, and the flow waits for no model reading. A quit resumes at the same step, with what was typed. Bean logs nothing, watches nothing and calls no model until its step in this flow.

## Sub-features

- `onboarding-ask`: the words go to `goals.md` as written, with no model call. "Not sure yet" writes nothing and goes away once something is typed.
- `onboarding-model`: on this Mac, a model from a local server the person runs, tried once with a tool call and a JSON answer. In the cloud, Muse Spark, with a live check of the key, and a refused key is removed. When a key and a local model are both there, Bean waits for a choice instead of checking the key by itself.
- `onboarding-setup`: passing the key starts the Strands install in the background. It never blocks a step, resumes after a quit, and turns on by itself. The person sees it only on the closing screen, if it is still running or failed.
- `onboarding-sees`: what Bean notices and reads. Off limits can be added here.
- `onboarding-access`: the pane's real name on this macOS, skipped when it is already on. A prompt the first time, the pane after that, a real read to confirm, and the flow moves on by itself.
- `onboarding-job`: Bean writes the goal from what it understood, and the person's sentence stays in `born_from`. If Bean does not understand, it asks one question and writes the agent with the answer. A change goes through the same writing, on the same agent, before the drag.
- `onboarding-drag`: missed drops go home, and after two a button places it.
- `onboarding-resume`: position and draft in `onboarding.json`.

## How to get to it (user POV)

- First launch of Bean with no data.
- Closed before the end: a hover or click on the notch, or a click on the Dock icon, reopens the same step.

## Driving it with bean

Preconditions:

- A test data folder skips the flow, so `BEAN_ONBOARDING=1` is required. Start from an empty run folder.
- `BEAN_WINDOW_FILTER` on a window of the run, `BEAN_IGNORE_ENV_FILE=1`, and for a fake model `BEAN_BASE_URL` with a generated test key. Strands needs `BEAN_DECIDER=strands` and `BEAN_STRANDS_HOME=<empty test folder>`, or nothing installs.

- **Look without the screen.** `BEAN_DATA_DIR=<empty folder> BEAN_IGNORE_ENV_FILE=1 Bean --probe-onboarding <folder>` writes every step as PNGs, with no input and no model.
- **Each step.** `bean press "<button>"` and `bean fill "<text>"`. Capture with `screencapture -l <window number>`.
- **The drag.** `bean head <agent>`, then `bean drag` from it onto `bean fixture` or into Bean's own window for a miss.
- **Resume.** Kill the recorded PID, `bean launch` again, and read `data/onboarding.json`.
- **No switch.** Copy the app, set another `CFBundleIdentifier`, sign it with the local identity, and start it with `open`. A process started from a trusted shell inherits its trust.
- **Strands from nothing.** `CFFIXED_USER_HOME=<empty folder>` with `BEAN_DECIDER=strands` makes `~/Models/strands-decider` land there, without touching the real install.
- **No network.** Start the binary under `sandbox-exec -p '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))'`. A fake model on localhost still answers.
- **Proof.** `goals.md`, `onboarding.json`, no `Events` folder before the last button, and the model log holding no call before the maker's.

## Gotchas

- A real macOS prompt, and the switch turning on, can only be judged by a person.
- `bean fill` clicks the field, which drops a selection, so a typed string appends.
- Strands is 5.7 GB and needs Apple silicon.
- A test window stops forming moments after its first one for an hour, so a second check on the same data folder proves nothing.
- A dead Strands server costs one wait of 90 s, then nothing for 5 minutes. Hold a window that long before reading `gate.jsonl`.
