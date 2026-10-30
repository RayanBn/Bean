# Calls

When an app holds the microphone or, in front, the camera, for a few seconds, and an agent sits on a window of that app, the agent can hear the call. No app list is involved. The first time, it asks in the page. Once allowed, it records and shows that it does: a journal line, a "Recording this call" bubble and `worker.listening`. The sound is transcribed on this Mac and never written to disk. At the end, the transcript goes in the agent's `calls/` folder, its recap and tasks in its thread, and both to Bean, who reports once.

## Sub-features

- `calls-detect`: `CallWatcher` finds the process holding the mic, and matches it to an agent through its parents, so a browser helper counts as its browser. It starts after 3 s (`BEAN_CALL_START_SECONDS`) and ends 8 s after the mic is released (`BEAN_CALL_END_SECONDS`).
- `calls-consent`: a need with `callConsent`. "Yes, listen to calls here" adds the ability `hear calls`, which the agent's switch can turn off, and it no longer asks. "Not this call" records nothing and asks again next call. With no answer, nothing is recorded.
- `calls-recap`: `AgentWorker.callEnded` asks the agent for the recap and tasks, then hands them to Bean.

## How to get to it (user POV)

Put an agent on a window of the app and start a call there. Answer the card in the page.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). A test agent in the run's data, attached to the app under test.
- A key for the model. `BEAN_DECIDER=muse` is enough.
- **Never use a real call or real people without the PM's slot.**

- **Prepare.** `swift .claude/skills/verify/bin/fake-call.swift <script> <dir>` writes `me.caf` and `them.caf`, one line per sentence: `me|<voice>|<text>`. It plays nothing.
- **Off screen.** `BEAN_MIC_FILE=<dir>/me.caf BEAN_THEM_FILE=<dir>/them.caf BEAN_CALL_LOCALE=en_US bean agents hear <agent-id> <seconds> yes|no`. It simulates the call and answers the card. No mic and no system audio are used. `hearing.jsonl` shows `askedConsent`, `consented` or `declined`, `recording`, `transcribed` with frame counts. The agent's journal has the recap, and Bean's the hand-off.
- **Detection.** `bean agents call-watch 20` with `swift .claude/skills/verify/bin/holdmic.swift 10` running holds the real mic and prints `start` and `end` with the process chain. The orange dot shows.
- **In the app.** It takes a slot: a private call, alone, on a window with an agent. macOS asks once for the microphone and for system audio.

## Gotchas

- The real recorder needs Bean to have the microphone and System Audio Recording permissions, under Bean's own identity: launch with `BEAN_LAUNCH_OPEN=1`. Without system audio, `them` stays silent.
- A window on another Space or a browser's other tab does not matter: detection follows the process, not the tab, so a mic used by any tab of that browser counts.
- Only the agent's app triggers a call, so a Dictation or Voice Memos use elsewhere is ignored.
