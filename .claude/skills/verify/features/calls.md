# Calls

An agent can ask to hear the calls on its window, when its mission needs it. Nothing listens until one has asked and the user said yes. Then, when that app holds the microphone or, in front, the camera, the agent records and shows that it does: a journal line, a "Recording this call" bubble and `worker.listening`. The sound is transcribed on this Mac and never written to disk. At the end, the transcript goes in the agent's `calls/` folder, its recap and tasks in its thread, and both to Bean, who reports once.

## Sub-features

- `calls-sense`: `CallSense` in `Features/Followup` is a self-contained unit that knows nothing of agents: what it detects, the permissions it needs, and its events (`started`, `recording`, `ended`, `heard`, `failed`). `CallWatcher` finds the process holding the mic. It starts after 3 s (`BEAN_CALL_START_SECONDS`) and ends 8 s after the mic is released (`BEAN_CALL_END_SECONDS`).
- `calls-request`: the tool `request_hearing_calls`, on an agent with a window. The need has `consent`. "Yes" adds the ability `hear calls`, which its switch can turn off. "Not now" records nothing.
- `calls-request-proof`: run `hearing2`: an agent whose mission is about calls asked in 3 of 3 runs, and one about a budget sheet in 0 of 2.
- `calls-listening`: `CallListening` starts the sense once an agent holds the ability, matches a call to that agent through the process's parents, and on `heard` asks the agent for the recap and tasks and hands them to Bean.

## How to get to it (user POV)

Put an agent whose mission needs calls on a window of the app. Answer its card in the page, then start a call there.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). A test agent in the run's data, attached to the app under test.
- A key for the model. `BEAN_DECIDER=muse` is enough.
- **Never use a real call or real people without the PM's slot.**

- **Prepare.** `swift .claude/skills/verify/bin/fake-call.swift <script> <dir>` writes `me.caf` and `them.caf`, one line per sentence: `me|<voice>|<text>`. It plays nothing.
- **Request.** `bean agents work <agent-id> 1` on an agent with a window and a mission about calls: `needs.json` has `consent`. An agent with another mission does not ask.
- **Off screen.** With the ability on: `BEAN_MIC_FILE=<dir>/me.caf BEAN_THEM_FILE=<dir>/them.caf BEAN_CALL_LOCALE=en_US bean agents hear <agent-id> <seconds>`. It simulates the call. No mic and no system audio are used. `hearing.jsonl` shows `recording` and `transcribed` with frame counts. The agent's journal has the recap, and Bean's the hand-off.
- **Detection.** `bean agents call-watch 20` with `swift .claude/skills/verify/bin/holdmic.swift 10` running holds the real mic and prints `start` and `end` with the process chain. The orange dot shows.
- **In the app.** It takes a slot: a private call, alone, on a window with an agent. macOS asks once for the microphone and for system audio.

## Gotchas

- The real recorder needs Bean to have the microphone and System Audio Recording permissions, under Bean's own identity: launch with `BEAN_LAUNCH_OPEN=1`. Without system audio, `them` stays silent.
- A window on another Space or a browser's other tab does not matter: detection follows the process, not the tab, so a mic used by any tab of that browser counts.
- Only the agent's app triggers a call, so a Dictation or Voice Memos use elsewhere is ignored.
