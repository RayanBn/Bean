# Onboarding

On a first launch a small window opens and Bean asks what it should take care of. It then asks where its brain runs and checks the key, says what it notices and lets the person close things off, gets the macOS switch, makes the first agent from the person's sentence, and waits for a real drag from the notch onto a window. The agent reads that window, changes nothing, and gives a first result. A quit resumes at the same step. Bean logs nothing, watches nothing and calls no model until its step in this flow.

## Sub-features

- `onboarding-ask`: the objective goes to `goals.md` word for word, with no model call. "Not sure yet" writes nothing.
- `onboarding-brain`: on this Mac, not available yet. In the cloud, Muse Spark. A live check of the key, and a refused key is removed.
- `onboarding-strands`: passing the key starts the Strands install in the background. It never blocks a step, resumes after a quit, and turns on by itself.
- `onboarding-sees`: what Bean notices, reads and sends. Off limits can be added here.
- `onboarding-switch`: the pane's real name on this macOS. A prompt the first time, the pane after that, a real read to confirm.
- `onboarding-drag`: the agent is made from the sentence alone. Missed drops go home, and after two a button places it.
- `onboarding-result`: the first run reads only, enforced in code. "No, do this instead" sends the correction to the agent.
- `onboarding-resume`: position in `onboarding.json`.

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
- **Proof.** `goals.md`, `onboarding.json`, no `Events` folder before the last button, and the model log holding no call before the maker's.

## Gotchas

- A real macOS prompt, and the switch turning on, can only be judged by a person.
- `bean fill` clicks the field, which drops a selection, so a typed string appends.
- Strands is 5.7 GB and needs Apple silicon.
